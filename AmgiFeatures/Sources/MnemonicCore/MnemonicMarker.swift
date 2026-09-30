//
//  MnemonicMarker.swift
//  MnemonicCore
//

import Foundation

/// The HTML-comment markers that make a note its own mnemonic queue.
///
/// A captured idea is written into the note as
///
///     <!--amgi-mnemonic:pending:ID:IDEA-->
///
/// and an approved picture replaces it with
///
///     <div class="amgi-mnemonic"><!--amgi-mnemonic:done:ID:PROMPT--><img …></div>
///
/// Comments never render, so a pending idea leaves the card looking exactly
/// as it did. Keeping the queue inside the note rather than in app storage
/// is deliberate: the idea syncs with the collection, survives a reinstall,
/// and can never lose track of which card it belongs to.
public enum MnemonicMarker {
    static let pendingPrefix = "<!--amgi-mnemonic:pending:"
    static let donePrefix = "<!--amgi-mnemonic:done:"
    static let close = "-->"

    /// One pending marker found in a field.
    struct Found {
        /// The whole marker, `<!--` through `-->`.
        let range: Range<String.Index>
        let id: String
        let idea: String
    }

    /// A short random ID. Only has to be unique within one note, and it
    /// becomes part of a media filename, so it stays lowercase hex.
    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10))
    }

    public static func pending(id: String, idea: String) -> String {
        "\(pendingPrefix)\(id):\(encode(idea))\(close)"
    }

    /// What an approved picture looks like in the field. The `done` comment
    /// keeps the prompt that made the picture, so it can be regenerated later
    /// with a better model without re-inventing the idea — and doubles as
    /// the idempotency key: an approval that finds it does nothing.
    public static func doneBlock(id: String, prompt: String, mediaFilename: String) -> String {
        "<div class=\"amgi-mnemonic\">\(donePrefix)\(id):\(encode(prompt))\(close)"
            + "<img src=\"\(mediaFilename)\" style=\"max-width:100%;height:auto\"></div>"
    }

    static func containsDone(id: String, in text: String) -> Bool {
        text.contains("\(donePrefix)\(id):")
    }

    /// Every pending marker in `text`, in order.
    static func pendingMarkers(in text: String) -> [Found] {
        var found: [Found] = []
        var searchFrom = text.startIndex
        while let start = text.range(of: pendingPrefix, range: searchFrom..<text.endIndex),
              let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
            let body = text[start.upperBound..<end.lowerBound]
            if let colon = body.firstIndex(of: ":") {
                let id = String(body[..<colon])
                let payload = String(body[body.index(after: colon)...])
                if !id.isEmpty {
                    found.append(Found(range: start.lowerBound..<end.upperBound, id: id, idea: decode(payload)))
                }
            }
            searchFrom = end.upperBound
        }
        return found
    }

    /// Percent-encodes exactly the characters that could end or corrupt an
    /// HTML comment (`-` and `>`, so `-->` can never appear), plus `%` itself
    /// so decoding is unambiguous, `<`, and line breaks. Everything else —
    /// spaces, punctuation, emoji — stays readable if you open the field in
    /// desktop Anki's HTML editor.
    static func encode(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "%": out += "%25"
            case "-": out += "%2D"
            case ">": out += "%3E"
            case "<": out += "%3C"
            case "\n": out += "%0A"
            case "\r": out += "%0D"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Falls back to the raw payload if someone hand-edited it into
    /// something that isn't valid percent-encoding.
    static func decode(_ payload: String) -> String {
        payload.removingPercentEncoding ?? payload
    }
}
