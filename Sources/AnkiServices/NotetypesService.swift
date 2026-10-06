//
//  NotetypesService.swift
//  AnkiServices
//
//  Created by Vladimir Gusev on 01.04.2026.
//

import AnkiBackend
import AnkiProtoBridge
public import AnkiKit
public import Dependencies
import DependenciesMacros

@DependencyClient
public struct NotetypesService: Sendable {
    public var getNotetypeNames: @Sendable () throws -> [(id: NotetypeID, name: String)]
    public var getNotetype: @Sendable (_ id: NotetypeID) throws -> NotetypeInfo
    /// Returns full per-field info (name, ordinal, font, size) for a notetype.
    /// Used by typed-answer rendering in ReviewSession.
    public var getNotetypeFields: @Sendable (_ id: NotetypeID) throws -> [NotetypeFieldInfo]
}

extension NotetypesService: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend
        return Self(
            getNotetypeNames: {
                try backend.invoke(.notetypeNames).map { (id: $0.id, name: $0.name) }
            },
            getNotetype: { id in
                let notetype = try backend.invoke(.notetype(for: id))
                let fieldNames = notetype.fields.map(\.name)
                let isCloze = notetype.config.kind == .cloze
                    && notetype.config.originalStockKind != .imageOcclusion
                let clozeFields = NotetypeInfo.clozeFieldNames(
                    in: notetype.templates.map(\.config.qFormat),
                    fieldNames: fieldNames
                )
                return NotetypeInfo(
                    id: notetype.id,
                    name: notetype.name,
                    fieldNames: fieldNames,
                    isCloze: isCloze,
                    // A template that hides its cloze field from the
                    // parser: the first field, where Anki's own puts it.
                    clozeFieldNames: isCloze ? (clozeFields.isEmpty ? Array(fieldNames.prefix(1)) : clozeFields) : [],
                    stickyFieldNames: notetype.fields.filter(\.config.sticky).map(\.name)
                )
            },
            getNotetypeFields: { id in
                let notetype = try backend.invoke(.notetype(for: id))
                return notetype.fields.map { field in
                    NotetypeFieldInfo(
                        name: field.name,
                        ordinal: field.ord ?? 0,
                        fontName: field.config.fontName.isEmpty ? "-apple-system" : field.config.fontName,
                        fontSize: field.config.fontSize == 0 ? 18 : field.config.fontSize
                    )
                }
            }
        )
    }()
}

extension NotetypesService: TestDependencyKey {
    public static let testValue = NotetypesService()
}

extension DependencyValues {
    public var notetypesService: NotetypesService {
        get { self[NotetypesService.self] }
        set { self[NotetypesService.self] = newValue }
    }
}
