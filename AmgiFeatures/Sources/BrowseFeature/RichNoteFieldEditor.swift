//
//  RichNoteFieldEditor.swift
//  BrowseFeature
//
//  Created by Vladimir Gusev on 28.04.2026.
//

import SwiftUI

#if canImport(UIKit)
import AnkiClients
import Dependencies
import UIKit
import UniformTypeIdentifiers

/// A note field editor. Anki stores fields as HTML fragments; a field with no
/// markup but line breaks is edited as plain text, anything else as its HTML
/// source, so editing never deletes formatting or pictures. See `FieldText`.
/// No `NSAttributedString` HTML parsing: that path is crash-prone.
///
/// Pictures show as themselves, not as their `<img>` tags, which are
/// written back as they were (`FieldPictures`); one whose file isn't in the
/// media folder shows as its tag. A picture pasted into the field (Paste in
/// the menu, or ⌘V) is stored as media and shown where the cursor is; a
/// field edited as plain text is edited as HTML from then on, to hold it.
/// Copy and Cut keep a picture's tag, so it pastes as the picture again.
///
/// With `clozeTools`, for the field a cloze note's deletions go in, the bar
/// above the keyboard starts with them: Cloze hides the selection on a card
/// of its own, Same Card on the card of the last one, the c1/c2 button
/// moves the deletion the cursor is in to another card, Hint gives it a
/// hint, Unwrap takes it away, and Renumber numbers them all in order.
struct RichNoteFieldEditor: UIViewRepresentable {
    @Binding var htmlText: String
    var preservesSourceHTML = false
    var clozeTools = false
    /// Takes the keyboard as it appears: the next note's first field.
    var focusOnAppear = false

    static func normalizedStoredHTML(_ text: String) -> String {
        Coordinator.normalizedStoredHTML(from: text)
    }

    /// Whether a field with this content opens as HTML source.
    static func editsAsSource(_ html: String) -> Bool {
        !FieldText.isPlain(html)
    }

    private let doneButtonTitle = "Done"
    private let boldTitle = "Bold"
    private let italicTitle = "Italic"
    private let underlineTitle = "Underline"
    private let strikeTitle = "Strikethrough"
    private let clearFormatTitle = "Clear formatting"

    /// The editing mode is settled once, from the field as it opens, so it
    /// can't flip in the middle of typing.
    func makeCoordinator() -> Coordinator {
        Coordinator(
            htmlText: $htmlText,
            editsSource: preservesSourceHTML || Self.editsAsSource(htmlText),
            clozeTools: clozeTools
        )
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = PictureTextView()
        textView.delegate = context.coordinator
        let coordinator = context.coordinator
        textView.onPastePictures = { [weak coordinator] pictures in
            coordinator?.pastePictures(pictures)
        }
        textView.onPasteMarkup = { [weak coordinator] markup in
            coordinator?.insertMarkup(markup)
        }
        textView.copiedSource = { [weak coordinator, weak textView] in
            guard let coordinator, let textView else { return nil }
            return coordinator.copiedSource(in: textView)
        }
        textView.becomesFirstResponderOnAppear = focusOnAppear
        // Bold, italic and the rest are for HTML: shown once a pasted
        // picture turns a plain-text field into HTML.
        coordinator.rebuildToolbar = { [weak coordinator] textView in
            guard let coordinator else { return }
            textView.inputAccessoryView = makeInputToolbar(for: textView, coordinator: coordinator)
            textView.reloadInputViews()
            coordinator.refreshClozeTools()
        }
        textView.isEditable = true
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.layer.cornerRadius = 0
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textColor = .label
        context.coordinator.attach(textView: textView)
        textView.inputAccessoryView = makeInputToolbar(for: textView, coordinator: context.coordinator)

        let display = displayText(for: htmlText, editsSource: context.coordinator.editsSource)
        context.coordinator.show(display, in: textView)
        context.coordinator.lastRenderedValue = htmlText
        context.coordinator.lastPlainText = display
        context.coordinator.refreshClozeTools()
        return textView
    }

    /// Gone from the screen, as when the next note's fields are made: it
    /// mustn't write the text it showed back over theirs on its way out.
    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        uiView.delegate = nil
    }

    /// As tall as the whole field, so the form scrolls through it. Capping
    /// the height (it was 160 pt) cut long fields off: scrolling inside the
    /// text view is off, so the rest of the field was unreachable.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(32, ceil(fit.height)))
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if context.coordinator.clozeTools != clozeTools {
            context.coordinator.clozeTools = clozeTools
            context.coordinator.rebuildToolbar?(uiView)
        }
        guard !context.coordinator.isEditing else { return }
        guard htmlText != context.coordinator.lastRenderedValue else { return }

        let displayedText = displayText(for: htmlText, editsSource: context.coordinator.editsSource)
        if context.coordinator.source(of: uiView) != displayedText {
            context.coordinator.show(displayedText, in: uiView)
        }
        context.coordinator.lastRenderedValue = htmlText
        context.coordinator.lastPlainText = displayedText
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var htmlText: String
        /// HTML source rather than plain text; see `FieldText`. Settled as
        /// the field opens, unless a picture is pasted into plain text.
        private(set) var editsSource: Bool
        weak var textView: UITextView?
        var rebuildToolbar: ((UITextView) -> Void)?
        @Dependency(\.mediaClient) private var mediaClient
        /// The cloze buttons, for the field cloze deletions go in.
        var clozeTools: Bool
        weak var clozeNumberButton: UIButton?
        weak var clozeHintButton: UIButton?
        weak var clozeUnwrapButton: UIButton?
        weak var clozeRenumberButton: UIButton?
        var lastRenderedValue: String = ""
        var lastPlainText: String = ""
        var isEditing = false

        init(htmlText: Binding<String>, editsSource: Bool, clozeTools: Bool) {
            self._htmlText = htmlText
            self.editsSource = editsSource
            self.clozeTools = clozeTools
        }

        func attach(textView: UITextView) {
            self.textView = textView
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
            commit(source(of: textView))
        }

        func textViewDidChange(_ textView: UITextView) {
            commit(source(of: textView))
            showPicturesTyped(in: textView)
            Self.keepCaretVisible(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            refreshClozeTools()
        }

        /// The field grows as it's typed into; once it has, scroll the form
        /// so the line being typed isn't left under the keyboard. A no-op
        /// whenever the caret is already in view.
        static func keepCaretVisible(in textView: UITextView) {
            Task { @MainActor [weak textView] in
                // Let the grown field be laid out first.
                try? await Task.sleep(for: .milliseconds(30))
                guard let textView, let position = textView.selectedTextRange?.end else { return }
                var ancestor = textView.superview
                while let view = ancestor, !(view is UIScrollView) {
                    ancestor = view.superview
                }
                guard let scrollView = ancestor as? UIScrollView else { return }
                let caret = textView.caretRect(for: position).insetBy(dx: 0, dy: -16)
                scrollView.scrollRectToVisible(textView.convert(caret, to: scrollView), animated: false)
            }
        }

        func insert(_ string: String) {
            guard let textView, let range = textView.selectedTextRange else { return }
            textView.replace(range, withText: string)
            commit(source(of: textView))
            showPicturesTyped(in: textView)
        }

        // MARK: Pictures

        /// What the editor's text is set in, the pictures among it too.
        var textAttributes: [NSAttributedString.Key: Any] {
            [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
        }

        /// Shows `display` in the text view, each picture whose file is in
        /// the media folder as the picture, with the cursor at `caret` (an
        /// offset in `display`) or where it was.
        func show(_ display: String, in textView: UITextView, caret: Int? = nil) {
            let previous = textView.selectedRange
            let shown = rendered(display)
            textView.attributedText = shown
            textView.typingAttributes = textAttributes
            let location: Int
            if let caret {
                let upToCaret = (display as NSString).substring(to: min(max(caret, 0), (display as NSString).length))
                location = rendered(upToCaret).length
            } else {
                location = previous.location
            }
            textView.selectedRange = NSRange(location: min(max(location, 0), shown.length), length: 0)
        }

        /// The field's text with each picture shown back as its tag.
        func source(of textView: UITextView) -> String {
            guard let shown = textView.attributedText else { return textView.text ?? "" }
            return Self.source(of: shown)
        }

        /// The selection with its pictures as their tags, for Copy and Cut;
        /// nil when there's no picture in it, for the usual copy.
        func copiedSource(in textView: UITextView) -> String? {
            let selected = textView.selectedRange
            guard selected.length > 0, let shown = textView.attributedText,
                  NSMaxRange(selected) <= shown.length else { return nil }
            let part = shown.attributedSubstring(from: selected)
            guard part.string.contains("\u{FFFC}") else { return nil }
            return Self.source(of: part)
        }

        private static func source(of shown: NSAttributedString) -> String {
            let string = shown.string as NSString
            var result = ""
            var start = 0
            for index in 0..<string.length where string.character(at: index) == 0xFFFC {
                result += string.substring(with: NSRange(location: start, length: index - start))
                // A stand-in for a picture that's gone has nothing to keep.
                if let picture = shown.attribute(.attachment, at: index, effectiveRange: nil) as? PictureAttachment {
                    result += picture.tag
                }
                start = index + 1
            }
            return result + string.substring(from: start)
        }

        /// `display` with each picture whose file is here in place of its
        /// tag. In plain text a tag is only typed text, and stays so.
        private func rendered(_ display: String) -> NSAttributedString {
            let attributes = textAttributes
            let result = NSMutableAttributedString(string: display, attributes: attributes)
            guard editsSource else { return result }
            for tag in FieldPictures.tags(in: display).reversed() {
                guard let image = picture(named: tag.filename) else { continue }
                let shown = NSMutableAttributedString(attachment: PictureAttachment(tag: tag.tag, image: image))
                shown.addAttributes(attributes, range: NSRange(location: 0, length: shown.length))
                result.replaceCharacters(in: tag.range, with: shown)
            }
            return result
        }

        /// Pictures read from the media folder, by file, made small enough
        /// to show; nil for one that isn't there. Each is read once.
        private var loadedPictures: [String: UIImage?] = [:]

        private func picture(named filename: String) -> UIImage? {
            if let known = loadedPictures[filename] { return known }
            let media = mediaClient
            // As named, or with its %20s and the like read, as some decks
            // write them.
            let names = [filename, filename.removingPercentEncoding].compactMap { $0 }
            let image = names.lazy
                .compactMap { name in media.localURL(name).flatMap { UIImage(contentsOfFile: $0.path) } }
                .first
                .map(PictureAttachment.shrunk)
            loadedPictures[filename] = .some(image)
            return image
        }

        /// An `<img>` tag pasted or typed in as text shows its picture,
        /// once it's whole and its file is here.
        private func showPicturesTyped(in textView: UITextView) {
            // Not in the middle of composing a character, as for Korean.
            guard editsSource, textView.markedTextRange == nil else { return }
            let text = textView.text ?? ""
            guard text.range(of: "<img", options: .caseInsensitive) != nil,
                  FieldPictures.tags(in: text).contains(where: { picture(named: $0.filename) != nil })
            else { return }
            // Once the typing or paste is through.
            Task { @MainActor [weak self, weak textView] in
                guard let self, let textView, textView.markedTextRange == nil else { return }
                let shown = textView.attributedText ?? NSAttributedString()
                let caret = min(textView.selectedRange.location, shown.length)
                let upToCaret = shown.attributedSubstring(from: NSRange(location: 0, length: caret))
                self.show(self.source(of: textView), in: textView, caret: (Self.source(of: upToCaret) as NSString).length)
            }
        }

        /// Pasted pictures, each stored as media, their tags put where the
        /// cursor is. A tap of feedback says whether it worked.
        func pastePictures(_ pictures: [Data]) {
            let media = mediaClient
            Task { @MainActor [weak self] in
                var tags: [String] = []
                for data in pictures {
                    if let tag = await NotePaste.storePicture(data, in: media) {
                        tags.append(tag)
                    }
                }
                guard let self else { return }
                let feedback = UINotificationFeedbackGenerator()
                guard !tags.isEmpty else {
                    feedback.notificationOccurred(.error)
                    return
                }
                insertMarkup(tags.joined(separator: "<br>"))
                feedback.notificationOccurred(.success)
            }
        }

        // MARK: Cloze deletions

        /// The selection made a cloze deletion: on a card of its own (the
        /// next number), or with `sameCard` on the card of the highest
        /// number used, hidden together with what's there.
        func newCloze(sameCard: Bool) {
            guard let textView else { return }
            let text = textView.text ?? ""
            let number = sameCard ? ClozeEditing.highestNumber(in: text) : ClozeEditing.nextNumber(in: text)
            apply(ClozeEditing.wrapping(textView.selectedRange, in: text, number: number))
        }

        /// The deletion the cursor is in, moved to card `number`.
        func setClozeNumber(_ number: Int) {
            guard let textView, let cloze = currentCloze else { return }
            apply(ClozeEditing.renumbering(cloze, to: number, keeping: textView.selectedRange))
        }

        func editClozeHint() {
            guard let cloze = currentCloze else { return }
            apply(ClozeEditing.hint(for: cloze))
        }

        func removeCloze() {
            guard let cloze = currentCloze else { return }
            apply(ClozeEditing.removing(cloze))
        }

        func renumberClozes() {
            guard let textView,
                  let edit = ClozeEditing.renumberedInOrder(textView.text ?? "", keeping: textView.selectedRange)
            else { return }
            apply(edit)
        }

        /// The cloze buttons for where the cursor is: the number of the
        /// deletion it's in, with a menu to move it to another card; Hint
        /// and Unwrap only in one; Renumber only when the numbers are out
        /// of order.
        func refreshClozeTools() {
            guard clozeTools, let textView else { return }
            let text = textView.text ?? ""
            let current = ClozeEditing.cloze(at: textView.selectedRange, in: text)
            clozeHintButton?.isEnabled = current != nil
            clozeUnwrapButton?.isEnabled = current != nil
            clozeRenumberButton?.isEnabled = ClozeEditing.renumberedInOrder(text, keeping: textView.selectedRange) != nil
            guard let button = clozeNumberButton else { return }
            var configuration = button.configuration ?? .gray()
            if let current {
                let highest = ClozeEditing.highestNumber(in: text)
                configuration.title = "c\(current.number)"
                button.menu = UIMenu(title: "Which card hides it", children: (1...(highest + 1)).map { number in
                    UIAction(
                        title: number > highest ? "c\(number), a new card" : "c\(number)",
                        state: number == current.number ? .on : .off
                    ) { [weak self] _ in
                        self?.setClozeNumber(number)
                    }
                })
                button.isEnabled = true
                button.accessibilityLabel = "Card \(current.number). Choose another card for this cloze deletion"
            } else {
                configuration.title = "c#"
                button.menu = nil
                button.isEnabled = false
                button.accessibilityLabel = "Card number: put the cursor in a cloze deletion to change it"
            }
            button.configuration = configuration
        }

        private var currentCloze: ClozeEditing.Cloze? {
            guard let textView else { return nil }
            return ClozeEditing.cloze(at: textView.selectedRange, in: textView.text ?? "")
        }

        /// A cloze button's change, made through the text view so Undo
        /// takes it back, the last change first so the earlier offsets
        /// still hold.
        private func apply(_ edit: ClozeEditing.Edit) {
            guard let textView else { return }
            for change in edit.changes.sorted(by: { $0.range.location > $1.range.location }) {
                replace(change.range, with: change.replacement, in: textView)
            }
            textView.selectedRange = edit.selection
            commit(source(of: textView))
            refreshClozeTools()
            Self.keepCaretVisible(in: textView)
        }

        /// `replacement` in place of `range`, through the text view so Undo
        /// takes it back; pictures outside `range` stay as they are.
        private func replace(_ range: NSRange, with replacement: String, in textView: UITextView) {
            guard range.length > 0 || !replacement.isEmpty,
                  let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end)
            else { return }
            textView.replace(textRange, withText: replacement)
        }

        /// `markup` where the cursor is, in place of any selection. A field
        /// edited as plain text shows no tags, so it's edited as HTML from
        /// here on.
        func insertMarkup(_ markup: String) {
            guard let textView else { return }
            if editsSource {
                insert(markup)
            } else {
                let inserted = NotePaste.inserting(
                    markup,
                    intoPlainText: textView.text ?? "",
                    replacing: textView.selectedRange
                )
                editsSource = true
                show(inserted.display, in: textView, caret: inserted.caret)
                commit(inserted.display)
                rebuildToolbar?(textView)
            }
            Self.keepCaretVisible(in: textView)
        }

        /// The selection between `prefix` and `suffix`, which are put either
        /// side of it, so a picture in it stays.
        func wrapSelection(prefix: String, suffix: String) {
            guard let textView else { return }
            let selected = textView.selectedRange
            replace(NSRange(location: NSMaxRange(selected), length: 0), with: suffix, in: textView)
            replace(NSRange(location: selected.location, length: 0), with: prefix, in: textView)
            textView.selectedRange = NSRange(
                location: selected.location + (prefix as NSString).length,
                length: selected.length
            )
            commit(source(of: textView))
        }

        /// Bold, italic and the like taken out of the selection (or the
        /// whole field, with nothing selected), tag by tag, so pictures stay.
        func clearFormattingInSelection() {
            guard let textView else { return }
            let selected = textView.selectedRange
            let text = textView.text ?? ""
            let target = selected.length > 0 ? selected : NSRange(location: 0, length: (text as NSString).length)
            let formatting = Self.inlineFormatting.matches(in: text, range: target).map(\.range)
            for range in formatting.reversed() {
                replace(range, with: "", in: textView)
            }
            let removed = formatting.reduce(0) { $0 + $1.length }
            textView.selectedRange = NSRange(location: NSMaxRange(target) - removed, length: 0)
            commit(source(of: textView))
        }

        private static let inlineFormatting = try! NSRegularExpression(
            pattern: "</?(?:b|strong|i|em|u|s|strike|del)>|</?font[^>]*>|</?span[^>]*>",
            options: [.caseInsensitive]
        )

        static func normalizedStoredHTML(from text: String) -> String {
            guard text.localizedCaseInsensitiveContains("anki-mathjax") else { return text }
            let pattern = #"<anki-mathjax(?:[^>]*?block=\"(.*?)\")?[^>]*?>(.*?)</anki-mathjax>"#
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else {
                return text
            }

            let source = text as NSString
            var output = ""
            output.reserveCapacity(source.length)
            var currentLocation = 0

            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let fullRange = match.range(at: 0)
                output += source.substring(with: NSRange(location: currentLocation, length: fullRange.location - currentLocation))

                let blockValue: String? = {
                    let range = match.range(at: 1)
                    guard range.location != NSNotFound else { return nil }
                    return source.substring(with: range)
                }()

                let innerText: String = {
                    let range = match.range(at: 2)
                    guard range.location != NSNotFound else { return "" }
                    return source.substring(with: range)
                }()

                let trimmed = trimMathJaxBreaks(in: innerText)
                if let blockValue, !blockValue.isEmpty, blockValue.caseInsensitiveCompare("false") != .orderedSame {
                    output += #"\["# + trimmed + #"\]"#
                } else {
                    output += #"\("# + trimmed + #"\)"#
                }

                currentLocation = fullRange.location + fullRange.length
            }

            output += source.substring(from: currentLocation)
            return output
        }

    }
}

private extension RichNoteFieldEditor {
    func displayText(for html: String, editsSource: Bool) -> String {
        let normalized = Coordinator.normalizedStoredHTML(from: html)
        return editsSource ? FieldText.sourceDisplay(normalized) : FieldText.plainDisplay(normalized)
    }

    // MARK: - Toolbar

    func makeInputToolbar(for textView: UITextView, coordinator: Coordinator) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        container.backgroundColor = .secondarySystemBackground

        let divider = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = .separator
        container.addSubview(divider)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        container.addSubview(scrollView)

        let stackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 6
        scrollView.addSubview(stackView)

        if coordinator.clozeTools {
            addClozeButtons(to: stackView, coordinator: coordinator)
        }

        stackView.addArrangedSubview(
            makeSymbolButton(systemName: "arrow.uturn.backward", title: "Undo") {
                textView.undoManager?.undo()
            }
        )
        stackView.addArrangedSubview(
            makeSymbolButton(systemName: "arrow.uturn.forward", title: "Redo") {
                textView.undoManager?.redo()
            }
        )

        if coordinator.editsSource {
            stackView.addArrangedSubview(
                makeFormatButton(systemName: "bold", title: boldTitle) {
                    coordinator.wrapSelection(prefix: "<b>", suffix: "</b>")
                }
            )
            stackView.addArrangedSubview(
                makeFormatButton(systemName: "italic", title: italicTitle) {
                    coordinator.wrapSelection(prefix: "<i>", suffix: "</i>")
                }
            )
            stackView.addArrangedSubview(
                makeFormatButton(systemName: "underline", title: underlineTitle) {
                    coordinator.wrapSelection(prefix: "<u>", suffix: "</u>")
                }
            )
            stackView.addArrangedSubview(
                makeFormatButton(systemName: "strikethrough", title: strikeTitle) {
                    coordinator.wrapSelection(prefix: "<s>", suffix: "</s>")
                }
            )
            stackView.addArrangedSubview(
                makeFormatButton(systemName: "textformat", title: clearFormatTitle) {
                    coordinator.clearFormattingInSelection()
                }
            )
        }

        // Outside the scrolling buttons, so it's always in reach.
        let doneButton = makeTextButton(title: doneButtonTitle) {
            textView.resignFirstResponder()
        }
        container.addSubview(doneButton)

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 0.5),

            doneButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            doneButton.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -10),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 6),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -6),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -12),
        ])

        return container
    }

    /// Cloze, Same Card, the card number, Hint, Unwrap and Renumber.
    func addClozeButtons(to stackView: UIStackView, coordinator: Coordinator) {
        stackView.addArrangedSubview(makeClozeButton(
            title: "Cloze",
            label: "Cloze: hide the selection on a card of its own",
            prominent: true
        ) {
            coordinator.newCloze(sameCard: false)
        })
        stackView.addArrangedSubview(makeClozeButton(
            title: "Same Card",
            label: "Cloze on the same card: hide the selection along with the last one"
        ) {
            coordinator.newCloze(sameCard: true)
        })
        let number = makeClozeButton(title: "c#", label: "Card number", action: nil)
        number.showsMenuAsPrimaryAction = true
        coordinator.clozeNumberButton = number
        stackView.addArrangedSubview(number)
        let hint = makeClozeButton(title: "Hint", label: "Give this cloze deletion a hint") {
            coordinator.editClozeHint()
        }
        coordinator.clozeHintButton = hint
        stackView.addArrangedSubview(hint)
        let unwrap = makeClozeButton(title: "Unwrap", label: "Take away this cloze deletion, keeping its words") {
            coordinator.removeCloze()
        }
        coordinator.clozeUnwrapButton = unwrap
        stackView.addArrangedSubview(unwrap)
        let renumber = makeClozeButton(title: "Renumber", label: "Number the cloze deletions in order, from c1") {
            coordinator.renumberClozes()
        }
        coordinator.clozeRenumberButton = renumber
        stackView.addArrangedSubview(renumber)

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 20).isActive = true
        stackView.addArrangedSubview(separator)
    }

    func makeClozeButton(title: String, label: String, prominent: Bool = false, action: (() -> Void)?) -> UIButton {
        var configuration: UIButton.Configuration = prominent ? .filled() : .gray()
        configuration.title = title
        configuration.buttonSize = .small
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = label
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        if let action {
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        }
        return button
    }

    func makeSymbolButton(systemName: String, title: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.accessibilityLabel = title
        button.tintColor = .label
        button.backgroundColor = .tertiarySystemFill
        button.layer.cornerRadius = 8
        var configuration = UIButton.Configuration.plain()
        configuration.buttonSize = .small
        configuration.baseBackgroundColor = .tertiarySystemFill
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        button.configuration = configuration
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    func makeFormatButton(systemName: String, title: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .systemBlue
        button.backgroundColor = .tertiarySystemFill
        button.layer.cornerRadius = 8
        button.accessibilityLabel = title
        var configuration = UIButton.Configuration.plain()
        configuration.buttonSize = .small
        configuration.baseBackgroundColor = .tertiarySystemFill
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        button.configuration = configuration
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    func makeTextButton(title: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = .tertiarySystemFill
        button.layer.cornerRadius = 8
        button.titleLabel?.font = .systemFont(ofSize: 11, weight: .medium)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
        button.titleLabel?.numberOfLines = 1
        var configuration = UIButton.Configuration.plain()
        configuration.buttonSize = .small
        configuration.baseBackgroundColor = .tertiarySystemFill
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        button.configuration = configuration
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
}

private extension RichNoteFieldEditor.Coordinator {
    /// Stores what the editor shows. A line break becomes `<br>`: a raw one
    /// is whitespace to the card.
    func commit(_ text: String) {
        let stored = editsSource ? FieldText.sourceStored(text) : FieldText.plainStored(text)
        let normalized = Self.normalizedStoredHTML(from: stored)
        lastPlainText = text
        lastRenderedValue = normalized
        htmlText = normalized
    }

    static func trimMathJaxBreaks(in text: String) -> String {
        text
            .replacingOccurrences(
                of: #"<br[ ]*/?>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: #"^\n*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n*$"#, with: "", options: .regularExpression)
    }
}

// MARK: - Pasting pictures

/// A text view whose Paste takes pictures as well as text: offered whenever
/// there's a picture on the clipboard, and handed to `onPastePictures`
/// rather than pasted as text. A picture copied along with its link or
/// caption pastes as the picture, as with the editor's Paste button.
private final class PictureTextView: UITextView {
    var onPastePictures: (([Data]) -> Void)?
    /// Text with a picture's `<img>` tag in it, from Copy in a field: put
    /// in as HTML, so the picture shows.
    var onPasteMarkup: ((String) -> Void)?
    /// The selection with its pictures as tags; nil without any.
    var copiedSource: (() -> String?)?
    var becomesFirstResponderOnAppear = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, becomesFirstResponderOnAppear else { return }
        becomesFirstResponderOnAppear = false
        // Once the form around it has settled.
        Task { @MainActor [weak self] in
            self?.becomeFirstResponder()
        }
    }

    override func copy(_ sender: Any?) {
        guard let source = copiedSource?() else { return super.copy(sender) }
        UIPasteboard.general.string = source
    }

    override func cut(_ sender: Any?) {
        guard let source = copiedSource?(), let selection = selectedTextRange else { return super.cut(sender) }
        UIPasteboard.general.string = source
        replace(selection, withText: "")
        delegate?.textViewDidChange?(self)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponderStandardEditActions.paste(_:)),
           isEditable, onPastePictures != nil, UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        if let onPastePictures, pasteboard.hasImages {
            let pictures = Self.pictures(on: pasteboard)
            if !pictures.isEmpty {
                onPastePictures(pictures)
                return
            }
        }
        if let onPasteMarkup, pasteboard.hasStrings, let text = pasteboard.string,
           !FieldPictures.tags(in: text).isEmpty {
            onPasteMarkup(text)
            return
        }
        super.paste(sender)
    }

    /// Each picture on the clipboard as it was copied, where it can be: a
    /// GIF keeps moving and a PNG its see-through parts. Otherwise as UIKit
    /// holds it.
    private static func pictures(on pasteboard: UIPasteboard) -> [Data] {
        var pictures: [Data] = []
        for item in pasteboard.items {
            let imageTypes = item.keys
                .compactMap { key in UTType(key).map { (key: key, type: $0) } }
                .filter { $0.type.conforms(to: .image) }
                .sorted { preference($0.type) < preference($1.type) }
            if let data = imageTypes.lazy.compactMap({ item[$0.key] as? Data }).first {
                pictures.append(data)
            } else if let data = imageTypes.lazy.compactMap({ (item[$0.key] as? UIImage)?.pngData() }).first {
                pictures.append(data)
            }
        }
        if pictures.isEmpty {
            pictures = (pasteboard.images ?? []).compactMap { $0.pngData() }
        }
        return pictures
    }

    private static func preference(_ type: UTType) -> Int {
        if type.conforms(to: .gif) { return 0 }
        if type.conforms(to: .png) { return 1 }
        if type.conforms(to: .jpeg) { return 2 }
        return 3
    }
}

/// A picture shown in a field in place of its `<img>` tag, which it keeps
/// to be written back as it was.
private final class PictureAttachment: NSTextAttachment {
    let tag: String

    /// The largest a picture shows in the editor; the card shows it as it is.
    static let maxSize = CGSize(width: 240, height: 180)

    init(tag: String, image: UIImage) {
        self.tag = tag
        super.init(data: nil, ofType: nil)
        self.image = image
        let scale = min(1, Self.maxSize.width / max(image.size.width, 1), Self.maxSize.height / max(image.size.height, 1))
        bounds = CGRect(
            x: 0,
            y: 0,
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
    }

    required init?(coder: NSCoder) {
        tag = ""
        super.init(coder: coder)
    }

    /// `image` no bigger than it's shown, sharp on any screen.
    static func shrunk(_ image: UIImage) -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let largest = CGSize(width: maxSize.width * 3, height: maxSize.height * 3)
        let factor = min(1, largest.width / max(pixels.width, 1), largest.height / max(pixels.height, 1))
        guard factor < 1 else { return image }
        let size = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
        return image.preparingThumbnail(of: size) ?? image
    }
}

#else

struct RichNoteFieldEditor: View {
    @Binding var htmlText: String
    var preservesSourceHTML = false
    var clozeTools = false
    var focusOnAppear = false

    var body: some View {
        TextEditor(text: $htmlText)
            .scrollContentBackground(.hidden)
    }
}

#endif
