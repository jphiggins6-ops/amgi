//
//  NotetypeTypes.swift
//  AnkiKit
//
//  Created by Vladimir Gusev on 01.04.2026.
//

public struct NotetypeInfo: Sendable {
    public let id: NotetypeID
    public let name: String
    public let fieldNames: [String]
    /// A cloze note type, whose cards come from the cloze deletions in its
    /// text (`{{c1::…}}`); Image Occlusion, a cloze type underneath, isn't
    /// counted.
    public let isCloze: Bool
    /// The fields cloze deletions go in: those its template reads with the
    /// `cloze` filter, `{{cloze:Text}}`. Empty unless `isCloze`.
    public let clozeFieldNames: [String]

    package init(
        id: NotetypeID,
        name: String,
        fieldNames: [String],
        isCloze: Bool = false,
        clozeFieldNames: [String] = []
    ) {
        self.id = id
        self.name = name
        self.fieldNames = fieldNames
        self.isCloze = isCloze
        self.clozeFieldNames = clozeFieldNames
    }

    /// The fields `templates` read with the `cloze` filter, on its own or
    /// among others (`{{cloze:Text}}`, `{{type:cloze:Text}}`), in field
    /// order.
    public static func clozeFieldNames(in templates: [String], fieldNames: [String]) -> [String] {
        var named: Set<String> = []
        for template in templates {
            var rest = template[...]
            while let open = rest.firstRange(of: "{{") {
                let afterOpen = rest[open.upperBound...]
                guard let close = afterOpen.firstRange(of: "}}") else { break }
                let parts = afterOpen[..<close.lowerBound].split(separator: ":", omittingEmptySubsequences: false)
                if let field = parts.last, parts.dropLast().contains(where: { trimmed($0) == "cloze" }) {
                    named.insert(trimmed(field))
                }
                rest = afterOpen[close.upperBound...]
            }
        }
        return fieldNames.filter { named.contains($0) }
    }

    private static func trimmed(_ text: Substring) -> String {
        var slice = text
        while let first = slice.first, first.isWhitespace { slice.removeFirst() }
        while let last = slice.last, last.isWhitespace { slice.removeLast() }
        return String(slice)
    }
}

/// Per-field config info for a notetype field — used by typed-answer rendering.
public struct NotetypeFieldInfo: Sendable {
    public let name: String
    public let ordinal: Int
    public let fontName: String
    public let fontSize: Int

    package init(name: String, ordinal: Int, fontName: String, fontSize: Int) {
        self.name = name
        self.ordinal = ordinal
        self.fontName = fontName
        self.fontSize = fontSize
    }
}

public struct NewNoteTemplate: Sendable {
    public let notetypeId: NotetypeID
    public var fields: [String]
    public var tags: [String]
    public let guid: String

    package init(notetypeId: NotetypeID, fields: [String], guid: String = "") {
        self.notetypeId = notetypeId
        self.fields = fields
        self.tags = []
        self.guid = guid
    }
}
