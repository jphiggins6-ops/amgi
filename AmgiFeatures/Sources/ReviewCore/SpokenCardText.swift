//
//  SpokenCardText.swift
//  ReviewCore
//

public import Foundation

/// What hands-free mode reads aloud: a rendered card side as speakable
/// text, split into runs by writing system so each can go to a voice that
/// speaks it.
public enum SpokenCardText {
    public enum Script: Equatable, Sendable {
        /// Latin and anything else: read in the phone's own language.
        case other
        case hangul
        case japanese
        case chinese
    }

    public struct Segment: Equatable, Sendable {
        public let text: String
        public let script: Script

        public init(text: String, script: Script) {
            self.text = text
            self.script = script
        }
    }

    // MARK: - Sides

    /// The question side, read as it shows. A cloze blank is read "blank".
    public static func question(fromHTML html: String) -> String {
        readable(html)
    }

    /// The answer side without the question above Anki's
    /// `<hr id=answer>`, so it isn't read twice. A side without that line,
    /// like a cloze card's, which is the sentence with the answer in it, is
    /// read whole.
    public static func answer(fromHTML html: String) -> String {
        let range = NSRange(html.startIndex..., in: html)
        if let match = answerDivider.firstMatch(in: html, range: range),
           let divider = Range(match.range, in: html) {
            return readable(String(html[divider.upperBound...]))
        }
        return readable(html)
    }

    /// A rendered side as text to speak. Anything the card doesn't show is
    /// left out: hidden elements (a hint's content until it's tapped),
    /// scripts, styles, icons and buttons. Pictures and sounds are skipped,
    /// and each line ends in a stop, so the voice pauses between lines.
    public static func readable(_ html: String) -> String {
        var text = replacing(comments, in: html, with: " ")
        text = withoutHiddenElements(text)
        text = replacing(clozeBlank, in: text, with: " blank ")
        text = replacing(soundTag, in: text, with: " ")
        text = replacing(mathDelimiter, in: text, with: " ")
        text = replacing(lineBreak, in: text, with: "\n")
        text = replacing(anyTag, in: text, with: " ")
        // &amp; last, or "&amp;lt;" would decode twice.
        for (entity, character) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&hellip;", "…"),
            ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return lines
            .map { line in line.last.map(sentenceEnds.contains) == true ? line : line + "." }
            .joined(separator: " ")
    }

    // MARK: - Voices

    /// `text` in runs of one writing system, so Korean is read by a Korean
    /// voice and the English beside it by an English one. Spaces, digits
    /// and punctuation join the run they're in. Chinese characters count as
    /// Japanese when the text has kana.
    public static func segments(_ text: String) -> [Segment] {
        let hasKana = text.unicodeScalars.contains { isKana($0.value) }
        var segments: [Segment] = []
        var run = ""
        var runScript: Script?
        for character in text {
            if let script = script(of: character, hasKana: hasKana) {
                if let current = runScript, current != script {
                    segments.append(Segment(text: run, script: current))
                    run = ""
                }
                runScript = script
            }
            run.append(character)
        }
        segments.append(Segment(text: run, script: runScript ?? .other))
        return segments
            .map { Segment(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), script: $0.script) }
            .filter { !$0.text.isEmpty }
    }

    /// Nil for what belongs to no writing system: spaces, digits, marks.
    static func script(of character: Character, hasKana: Bool) -> Script? {
        guard let scalar = character.unicodeScalars.first?.value else { return nil }
        if isHangul(scalar) { return .hangul }
        if isKana(scalar) { return .japanese }
        if isHan(scalar) { return hasKana ? .japanese : .chinese }
        return character.isLetter ? .other : nil
    }

    static func isHangul(_ scalar: UInt32) -> Bool {
        (0xAC00...0xD7A3).contains(scalar) || (0x1100...0x11FF).contains(scalar) || (0x3130...0x318F).contains(scalar)
    }

    static func isKana(_ scalar: UInt32) -> Bool {
        (0x3040...0x30FF).contains(scalar) || (0x31F0...0x31FF).contains(scalar) || (0xFF66...0xFF9F).contains(scalar)
    }

    static func isHan(_ scalar: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(scalar) || (0x3400...0x4DBF).contains(scalar) || (0xF900...0xFAFF).contains(scalar)
    }

    // MARK: - Hidden elements

    /// The HTML with every element the card doesn't show taken out, nested
    /// content and all. A regular expression can't match nested tags, so
    /// this walks them and counts depth.
    static func withoutHiddenElements(_ html: String) -> String {
        let source = html as NSString
        var output = ""
        var cursor = 0
        var skipping: (name: String, depth: Int)?
        for match in tag.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let tagRange = match.range
            if skipping == nil {
                output += source.substring(with: NSRange(location: cursor, length: tagRange.location - cursor))
            }
            cursor = tagRange.location + tagRange.length

            let isClosing = match.range(at: 1).length > 0
            let name = source.substring(with: match.range(at: 2)).lowercased()
            let attributes = source.substring(with: match.range(at: 3))
            let isEmptyElement = voidElements.contains(name) || attributes.hasSuffix("/")

            if let skip = skipping {
                if skip.name == name && !isEmptyElement {
                    let depth = skip.depth + (isClosing ? -1 : 1)
                    if depth == 0 {
                        skipping = nil
                    } else {
                        skipping = (name: name, depth: depth)
                    }
                }
                continue
            }
            if !isClosing && !isEmptyElement && hides(name: name, attributes: attributes) {
                skipping = (name: name, depth: 1)
                continue
            }
            output += source.substring(with: tagRange)
        }
        if skipping == nil, cursor < source.length {
            output += source.substring(from: cursor)
        }
        return output
    }

    static func hides(name: String, attributes: String) -> Bool {
        if notContent.contains(name) { return true }
        let range = NSRange(attributes.startIndex..., in: attributes)
        return hiddenAttributes.firstMatch(in: attributes, range: range) != nil
    }

    private static let notContent: Set<String> = ["script", "style", "svg", "button", "template", "head", "title", "audio", "video"]
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
    ]
    private static let sentenceEnds: Set<Character> = [".", "!", "?", ":", ";", "。", "！", "？", "…"]

    // MARK: - Patterns

    private static let tag = try! NSRegularExpression(pattern: #"<(/?)([a-zA-Z][a-zA-Z0-9-]*)([^>]*)>"#)
    /// `display: none`, the `hidden` attribute, or Anki's hint link
    /// (`class=hint`), which only says what the hidden content is called.
    private static let hiddenAttributes = try! NSRegularExpression(
        pattern: #"display\s*:\s*none|(^|\s)hidden(\s|=|/|$)|class\s*=\s*["']?[^"'>]*\bhint\b"#,
        options: [.caseInsensitive]
    )
    private static let answerDivider = try! NSRegularExpression(
        pattern: #"<hr[^>]*\bid\s*=\s*["']?answer["']?[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let comments = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)
    private static let clozeBlank = try! NSRegularExpression(pattern: #"\[(\.\.\.|…)\]"#)
    private static let soundTag = try! NSRegularExpression(pattern: #"\[sound:[^\]]*\]"#)
    private static let mathDelimiter = try! NSRegularExpression(pattern: #"\\[()\[\]]"#)
    private static let lineBreak = try! NSRegularExpression(
        pattern: #"<br\s*/?>|</(div|p|li|tr|h[1-6])\s*>|<hr\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let anyTag = try! NSRegularExpression(pattern: #"<[^>]*>"#)

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}
