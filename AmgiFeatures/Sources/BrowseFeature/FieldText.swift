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
