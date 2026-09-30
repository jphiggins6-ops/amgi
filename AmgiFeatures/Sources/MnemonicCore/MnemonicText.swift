//
//  MnemonicText.swift
//  MnemonicCore
//

import Foundation

public enum MnemonicText {
    /// A field's HTML reduced to one readable line: cloze deletions shown as
    /// their answers, tags / sound references / comments dropped, common
    /// entities decoded, whitespace collapsed. Context only — not a renderer.
    public static func summary(_ html: String, limit: Int = 160) -> String {
        var text = html
        text = replacing(#"\{\{c\d+::(.*?)(?:::[^}]*)?\}\}"#, in: text, with: "$1")
        text = replacing(#"\[sound:[^\]]*\]"#, in: text, with: " ")
        text = replacing(#"<[^>]*>"#, in: text, with: " ")
        // &amp; last, or "&amp;lt;" would decode twice.
        for (entity, character) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.count > limit {
            text = String(text.prefix(max(limit - 1, 0))) + "…"
        }
        return text
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}
