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
/// A picture pasted into the field (Paste in the menu, or ⌘V) is stored as
/// media and its tag put where the cursor is; a field edited as plain text
/// is edited as HTML from then on, to hold it.
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

        textView.text = displayText(for: htmlText, editsSource: context.coordinator.editsSource)
        context.coordinator.lastRenderedValue = htmlText
        context.coordinator.lastPlainText = textView.text ?? ""
        context.coordinator.refreshClozeTools()
        return textView
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
        if uiView.text != displayedText {
            let selected = uiView.selectedRange
            uiView.text = displayedText
            let maxLoc = max(0, min(selected.location, displayedText.utf16.count))
            uiView.selectedRange = NSRange(location: maxLoc, length: 0)
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
            commit(textView.text ?? "")
        }

        func textViewDidChange(_ textView: UITextView) {
            commit(textView.text ?? "")
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
            commit(textView.text ?? "")
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
            guard let textView, let cloze = currentCloze else { return }
            apply(ClozeEditing.removing(cloze, in: textView.text ?? ""))
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
        /// takes it back.
        private func apply(_ edit: ClozeEditing.Edit) {
            guard let textView else { return }
            if edit.range.length > 0 || !edit.replacement.isEmpty,
               let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
               let end = textView.position(from: start, offset: edit.range.length),
               let range = textView.textRange(from: start, to: end) {
                textView.replace(range, withText: edit.replacement)
            }
            textView.selectedRange = edit.selection
            commit(textView.text ?? "")
            refreshClozeTools()
            Self.keepCaretVisible(in: textView)
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
                textView.text = inserted.display
                textView.selectedRange = NSRange(location: inserted.caret, length: 0)
                commit(inserted.display)
                rebuildToolbar?(textView)
            }
            Self.keepCaretVisible(in: textView)
        }

        func wrapSelection(prefix: String, suffix: String) {
            guard let textView else { return }
            let selected = textView.selectedRange
            let original = textView.text ?? ""
            let source = original as NSString
            let selectedText = source.substring(with: selected)
            let replacement = "\(prefix)\(selectedText)\(suffix)"
            let updated = source.replacingCharacters(in: selected, with: replacement)
            textView.text = updated

            if selected.length == 0 {
                let cursor = selected.location + (prefix as NSString).length
                textView.selectedRange = NSRange(location: cursor, length: 0)
            } else {
                let rangeStart = selected.location + (prefix as NSString).length
                textView.selectedRange = NSRange(location: rangeStart, length: selected.length)
            }

            commit(updated)
        }

        func clearFormattingInSelection() {
            guard let textView else { return }
            let selected = textView.selectedRange
            let original = textView.text ?? ""
            let source = original as NSString

            let targetRange: NSRange
            if selected.length > 0 {
                targetRange = selected
            } else {
                targetRange = NSRange(location: 0, length: source.length)
            }

            let target = source.substring(with: targetRange)
            let cleaned = Self.removeInlineHTMLFormatting(from: target)
            let updated = source.replacingCharacters(in: targetRange, with: cleaned)
            textView.text = updated

            let cursor = targetRange.location + (cleaned as NSString).length
            textView.selectedRange = NSRange(location: cursor, length: 0)
            commit(updated)
        }

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

    static func removeInlineHTMLFormatting(from text: String) -> String {
        var output = text
        let patterns = [
            "(?i)</?(b|strong|i|em|u|s|strike|del)>",
            "(?i)</?font[^>]*>",
            "(?i)</?span[^>]*>"
        ]
        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return output
    }
}

// MARK: - Pasting pictures

/// A text view whose Paste takes pictures as well as text: offered whenever
/// there's a picture on the clipboard, and handed to `onPastePictures`
/// rather than pasted as text. A picture copied along with its link or
/// caption pastes as the picture, as with the editor's Paste button.
private final class PictureTextView: UITextView {
    var onPastePictures: (([Data]) -> Void)?

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

#else

struct RichNoteFieldEditor: View {
    @Binding var htmlText: String
    var preservesSourceHTML = false
    var clozeTools = false

    var body: some View {
        TextEditor(text: $htmlText)
            .scrollContentBackground(.hidden)
    }
}

#endif
