//
//  ExtraFieldMarker.swift
//  ReviewCore
//

public import Foundation

/// Marks where a note's Extra field begins in its rendered answer, so the
/// card page can open a gap above it when the template leaves none
/// (`amgiEnsureExtraGap` in CardWebViewBridge.js).
///
/// The Extra field is the first field with "extra" in its name ("Extra",
/// "Back Extra"). A plain `{{Extra}}` puts the field's HTML into the page
/// as it is, so it's found by looking for that HTML in the page's text,
/// never inside a tag, a script or a style, where a marker would break it.
public enum ExtraFieldMarker {
    public static let html = #"<span class="amgi-extra-start"></span>"#

    /// `backHTML` with the marker in front of the Extra field, or as it was
    /// when there's no such field, it's empty, or its HTML isn't in the page.
    public static func marking(_ backHTML: String, fieldNames: [String], fieldValues: [String]) -> String {
        for (index, name) in fieldNames.enumerated()
        where index < fieldValues.count && name.range(of: "extra", options: .caseInsensitive) != nil {
            let value = fieldValues[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, let start = firstOccurrenceInText(of: value, in: backHTML) else { continue }
            var marked = backHTML
            marked.insert(contentsOf: html, at: start)
            return marked
        }
        return backHTML
    }

    static func firstOccurrenceInText(of value: String, in html: String) -> String.Index? {
        var searchFrom = html.startIndex
        while searchFrom < html.endIndex, let found = html.range(of: value, range: searchFrom..<html.endIndex) {
            if isText(at: found.lowerBound, in: html) { return found.lowerBound }
            searchFrom = html.index(after: found.lowerBound)
        }
        return nil
    }

    /// Whether `index` is in the page's text: outside any tag, and not in a
    /// script or a style.
    static func isText(at index: String.Index, in html: String) -> Bool {
        let before = html[..<index]
        if let open = before.lastIndex(of: "<"), !before[open...].contains(">") { return false }
        let lowered = before.lowercased()
        for element in ["script", "style"] {
            let opened = lowered.components(separatedBy: "<\(element)").count - 1
            let closed = lowered.components(separatedBy: "</\(element)").count - 1
            if opened > closed { return false }
        }
        return true
    }
}
