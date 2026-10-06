//
//  FieldText.swift
//  BrowseFeature
//

import Foundation

/// How a note field's stored HTML becomes the text the editor shows, and
/// back. Anki starts a new line only at a `<br>`: a raw line break in a
/// field is plain whitespace to the card, so typing Return has to store
/// `<br>`, or the card runs the lines together.
///
/// Two ways to edit:
/// - **Plain** — the field has no markup but line breaks. It's shown as
///   ordinary text, `<br>` as a line break, and stored back escaped.
/// - **Source** — anything else (formatting, pictures, lists, comments).
///   Showing that as plain text and writing it back would delete it, so the
///   HTML is shown as it is, with each `<br>` starting a visible new line.
///
/// Either way a line break in the editor is stored as `<br>`, including one
/// that was stored raw before: what the editor shows is what the card shows.
enum FieldText {
    // MARK: - Mode

    /// True when the field can be edited as plain text without losing
    /// anything: its only tags are line breaks.
    static func isPlain(_ html: String) -> Bool {
        let range = NSRange(html.startIndex..., in: html)
        for match in markupRegex.matches(in: html, range: range) {
            let markup = (html as NSString).substring(with: match.range)
            let whole = NSRange(location: 0, length: (markup as NSString).length)
            guard wholeBrTag.firstMatch(in: markup, range: whole) != nil else { return false }
        }
        return true
    }

    // MARK: - Plain

    static func plainDisplay(_ html: String) -> String {
        var text = unifyLineEndings(html)
        // A raw break right after a <br> is whitespace the card never showed.
        text = replacing(brFollowedByNewline, in: text, with: "\n")
        text = replacing(brRegex, in: text, with: "\n")
        return decodeEntities(text)
    }

    static func plainStored(_ text: String) -> String {
        var stored = unifyLineEndings(text)
        // Escape a bare & but leave entities (&amp; &#39; &nbsp; …) alone.
        stored = replacing(bareAmpersand, in: stored, with: "&amp;")
        stored = stored
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return stored.replacingOccurrences(of: "\n", with: "<br>")
    }

    // MARK: - Source

    static func sourceDisplay(_ html: String) -> String {
        replacing(brNotFollowedByNewline, in: unifyLineEndings(html), with: "$0\n")
    }

    static func sourceStored(_ text: String) -> String {
        // Drop the line break shown after each <br>, then store every other
        // line break as a <br> of its own.
        let collapsed = replacing(brFollowedByNewline, in: unifyLineEndings(text), with: "$1")
        return collapsed.replacingOccurrences(of: "\n", with: "<br>")
    }

    // MARK: - Helpers

    /// Tags and comments.
    private static let markupRegex = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->|</?[a-zA-Z][^>]*>"#)
    private static let brRegex = try! NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive])
    private static let wholeBrTag = try! NSRegularExpression(pattern: #"^<br\s*/?>$"#, options: [.caseInsensitive])
    private static let brFollowedByNewline = try! NSRegularExpression(pattern: #"(<br\s*/?>)\n"#, options: [.caseInsensitive])
    private static let brNotFollowedByNewline = try! NSRegularExpression(pattern: #"<br\s*/?>(?!\n)"#, options: [.caseInsensitive])
    private static let bareAmpersand = try! NSRegularExpression(pattern: #"&(?!(?:[a-zA-Z][a-zA-Z0-9]*|#[0-9]+|#[xX][0-9a-fA-F]+);)"#)

    private static func unifyLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        // &amp; last, or "&amp;lt;" would decode twice.
        var result = text
        for (entity, character) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&"),
        ] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }
}

// MARK: - Cloze deletions

/// Cloze deletions in a field as its editor shows it, `{{c1::answer}}` or
/// `{{c1::answer::hint}}`, and the changes the editor's cloze buttons make.
/// Each number is a card of its own: everything numbered 1 is hidden on
/// card 1, and so on. Offsets are the text view's, UTF-16, as `NSRange`.
enum ClozeEditing {
    struct Cloze: Equatable {
        /// The whole deletion, braces and all.
        let range: NSRange
        let number: Int
        /// The number's digits, after the "c".
        let numberRange: NSRange
        let answerRange: NSRange
        /// After the second "::", when there's a hint.
        let hintRange: NSRange?
    }

    /// A change to the field: `replacement` in place of `range`, then the
    /// cursor or selection at `selection`.
    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
        let selection: NSRange
    }

    /// Every deletion, nested ones too, in the order they start.
    static func clozes(in text: String) -> [Cloze] {
        let source = text as NSString
        var found: [Cloze] = []
        var unclosed: [(start: Int, number: Int, numberRange: NSRange, answerStart: Int, hintStart: Int?)] = []
        var index = 0
        while index < source.length {
            if let opening = opening(at: index, in: source) {
                unclosed.append((index, opening.number, opening.numberRange, opening.end, nil))
                index = opening.end
            } else if !unclosed.isEmpty, starts(with: "}}", at: index, in: source) {
                let cloze = unclosed.removeLast()
                let answerEnd = cloze.hintStart.map { $0 - 2 } ?? index
                found.append(Cloze(
                    range: NSRange(location: cloze.start, length: index + 2 - cloze.start),
                    number: cloze.number,
                    numberRange: cloze.numberRange,
                    answerRange: NSRange(location: cloze.answerStart, length: answerEnd - cloze.answerStart),
                    hintRange: cloze.hintStart.map { NSRange(location: $0, length: index - $0) }
                ))
                index += 2
            } else if !unclosed.isEmpty, unclosed[unclosed.count - 1].hintStart == nil, starts(with: "::", at: index, in: source) {
                unclosed[unclosed.count - 1].hintStart = index + 2
                index += 2
            } else {
                index += 1
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// The card numbers used, each once, lowest first.
    static func numbers(in text: String) -> [Int] {
        Array(Set(clozes(in: text).map(\.number))).sorted()
    }

    /// The number a new card's deletion takes: one past the highest.
    static func nextNumber(in text: String) -> Int {
        (numbers(in: text).last ?? 0) + 1
    }

    /// The highest number used, 1 when there's none: for more hidden on
    /// the same card.
    static func highestNumber(in text: String) -> Int {
        max(numbers(in: text).last ?? 1, 1)
    }

    /// The innermost deletion the cursor or selection is in. The cursor
    /// just after one's closing braces counts as in it, so a deletion just
    /// made can be changed straight away.
    static func cloze(at selection: NSRange, in text: String) -> Cloze? {
        let start = selection.location
        let end = start + selection.length
        return clozes(in: text)
            .filter { cloze in
                cloze.range.location <= start && end <= NSMaxRange(cloze.range)
                    && !(selection.length == 0 && start == cloze.range.location)
            }
            .min { $0.range.length < $1.range.length }
    }

    /// The selection made a deletion numbered `number`, any spaces at its
    /// ends left outside it; with nothing selected, an empty one to type
    /// into. The cursor goes after it, or inside the empty one.
    static func wrapping(_ selection: NSRange, in text: String, number: Int) -> Edit {
        let source = text as NSString
        let location = min(max(selection.location, 0), source.length)
        var start = location
        var end = location + min(max(selection.length, 0), source.length - location)
        while start < end, isSpace(source.character(at: start)) { start += 1 }
        while end > start, isSpace(source.character(at: end - 1)) { end -= 1 }
        let opening = "{{c\(number)::"
        let answer = source.substring(with: NSRange(location: start, length: end - start))
        let replacement = opening + answer + "}}"
        let caret = answer.isEmpty
            ? start + (opening as NSString).length
            : start + (replacement as NSString).length
        return Edit(
            range: NSRange(location: start, length: end - start),
            replacement: replacement,
            selection: NSRange(location: caret, length: 0)
        )
    }

    /// `cloze` moved to card `number`; the cursor stays where it was.
    static func renumbering(_ cloze: Cloze, to number: Int, keeping selection: NSRange) -> Edit {
        let digits = String(number)
        var moved = selection
        if selection.location >= NSMaxRange(cloze.numberRange) {
            moved.location += (digits as NSString).length - cloze.numberRange.length
        }
        return Edit(range: cloze.numberRange, replacement: digits, selection: moved)
    }

    /// `cloze` taken away, its answer kept as ordinary text and any hint
    /// dropped; the cursor after the answer.
    static func removing(_ cloze: Cloze, in text: String) -> Edit {
        let answer = (text as NSString).substring(with: cloze.answerRange)
        return Edit(
            range: cloze.range,
            replacement: answer,
            selection: NSRange(location: cloze.range.location + (answer as NSString).length, length: 0)
        )
    }

    /// Somewhere to type `cloze`'s hint, shown in place of "[...]" while
    /// it's hidden: the hint there is selected, or a new "::" goes before
    /// the closing braces with the cursor after it.
    static func hint(for cloze: Cloze) -> Edit {
        if let hintRange = cloze.hintRange {
            return Edit(range: NSRange(location: hintRange.location, length: 0), replacement: "", selection: hintRange)
        }
        let closing = NSMaxRange(cloze.range) - 2
        return Edit(
            range: NSRange(location: closing, length: 0),
            replacement: "::",
            selection: NSRange(location: closing + 2, length: 0)
        )
    }

    /// Every deletion renumbered from 1 in the order its number first
    /// appears, so none is skipped: c3, c1, c3 becomes c1, c2, c1. Nil when
    /// they're in order already.
    static func renumberedInOrder(_ text: String, keeping selection: NSRange) -> Edit? {
        let all = clozes(in: text)
        var mapping: [Int: Int] = [:]
        for cloze in all where mapping[cloze.number] == nil {
            mapping[cloze.number] = mapping.count + 1
        }
        guard mapping.contains(where: { $0.key != $0.value }) else { return nil }
        let renumbered = NSMutableString(string: text)
        var moved = selection
        // From the end, so the offsets before each one still hold.
        for cloze in all.sorted(by: { $0.numberRange.location > $1.numberRange.location }) {
            let digits = String(mapping[cloze.number] ?? cloze.number)
            renumbered.replaceCharacters(in: cloze.numberRange, with: digits)
            if moved.location >= NSMaxRange(cloze.numberRange) {
                moved.location += (digits as NSString).length - cloze.numberRange.length
            }
        }
        return Edit(
            range: NSRange(location: 0, length: (text as NSString).length),
            replacement: renumbered as String,
            selection: moved
        )
    }

    // MARK: Reading the braces

    private static func opening(at index: Int, in source: NSString) -> (number: Int, numberRange: NSRange, end: Int)? {
        guard starts(with: "{{", at: index, in: source), index + 2 < source.length else { return nil }
        let letter = source.character(at: index + 2)
        guard letter == 0x63 || letter == 0x43 else { return nil }   // "c" or "C"
        var digitsEnd = index + 3
        while digitsEnd < source.length, (0x30...0x39).contains(source.character(at: digitsEnd)) {
            digitsEnd += 1
        }
        guard digitsEnd > index + 3, starts(with: "::", at: digitsEnd, in: source) else { return nil }
        let numberRange = NSRange(location: index + 3, length: digitsEnd - index - 3)
        guard let number = Int(source.substring(with: numberRange)) else { return nil }
        return (number, numberRange, digitsEnd + 2)
    }

    private static func starts(with token: String, at index: Int, in source: NSString) -> Bool {
        let length = (token as NSString).length
        guard index >= 0, index + length <= source.length else { return false }
        return source.substring(with: NSRange(location: index, length: length)) == token
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x0A || character == 0x09 || character == 0xA0
    }
}
