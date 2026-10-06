//
//  NotePaste.swift
//  BrowseFeature
//

import AnkiClients
import AppCore
import CoreTransferable
import CryptoKit
import Foundation
import ImageIO
import MnemonicCore
import OSLog
import UniformTypeIdentifiers

/// One thing on the clipboard, as the editor's Paste button hands it over.
enum PastedItem: Equatable, Sendable {
    case image(Data)
    case text(String)
}

extension PastedItem: Transferable {
    /// The first form the clipboard can supply wins, so a picture copied
    /// along with its link or caption pastes as the picture.
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            PastedItem.image(data)
        }
        DataRepresentation(importedContentType: .plainText) { data in
            PastedItem.text(NotePaste.decodedText(data))
        }
    }
}

/// Where the editor's Paste button puts things, and how they're written
/// into the field.
enum NotePaste {
    /// The field pasted things go to: the one a visual mnemonic's picture
    /// goes to — Extra, then Back Extra, then Back, otherwise the last.
    /// Nil before the note's fields have loaded.
    static func targetFieldIndex(fieldNames: [String], fieldCount: Int) -> Int? {
        guard fieldCount > 0 else { return nil }
        guard !fieldNames.isEmpty else { return fieldCount - 1 }
        return min(MnemonicNoteEditor.targetFieldIndex(fieldNames: fieldNames), fieldCount - 1)
    }

    /// `addition` on a line of its own at the end of `field`.
    static func appending(_ addition: String, to field: String) -> String {
        guard !addition.isEmpty else { return field }
        guard !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return addition }
        let range = NSRange(field.startIndex..., in: field)
        let endsLine = endsWithLineBreak.firstMatch(in: field, range: range) != nil
        return field + (endsLine ? "" : "<br>") + addition
    }

    /// Pasted text as field HTML: escaped like typed text, its line breaks
    /// as `<br>`, without the blank lines a copy often ends with.
    static func html(forText text: String) -> String {
        FieldText.plainStored(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func imageTag(filename: String) -> String {
        "<img src=\"\(filename)\">"
    }

    /// Saves a pasted picture to the media folder, made ready first
    /// (`PreparedImage`); returns the tag that shows it on the card, or nil
    /// when it isn't a picture or couldn't be saved.
    static func storePicture(_ data: Data, in media: MediaClient) async -> String? {
        let prepared = await Task.detached(priority: .userInitiated) {
            PreparedImage.prepare(data)
        }.value
        guard let prepared else { return nil }
        let filename = mediaFilename(for: prepared.data, fileExtension: prepared.fileExtension)
        do {
            try await media.save(prepared.data, filename)
            return imageTag(filename: filename)
        } catch {
            Log.browse.error("Saving a pasted picture failed: \(error)")
            return nil
        }
    }

    /// `markup` in place of `range` of a field edited as plain text, which
    /// is edited as HTML source from then on, as it now has a tag: what's
    /// stored, what the editor shows, and where its cursor goes, just after
    /// the markup.
    static func inserting(
        _ markup: String,
        intoPlainText text: String,
        replacing range: NSRange
    ) -> (stored: String, display: String, caret: Int) {
        let source = text as NSString
        let start = min(max(range.location, 0), source.length)
        let end = min(start + max(range.length, 0), source.length)
        let upToCaret = FieldText.plainStored(source.substring(to: start)) + markup
        let stored = upToCaret + FieldText.plainStored(source.substring(from: end))
        let display = FieldText.sourceDisplay(stored)
        let caret = min((FieldText.sourceDisplay(upToCaret) as NSString).length, (display as NSString).length)
        return (stored, display, caret)
    }

    /// Named for its content, as Anki names pasted pictures, so pasting the
    /// same picture twice keeps one file.
    static func mediaFilename(for data: Data, fileExtension: String) -> String {
        let hex = Insecure.SHA1.hash(data: data)
            .map { byte in (byte < 16 ? "0" : "") + String(byte, radix: 16) }
            .joined()
        return "paste-\(hex).\(fileExtension)"
    }

    static func decodedText(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\0", with: "")
    }

    /// A field that already ends its last line: a `<br>`, or the end of a
    /// block such as a `<div>`, which the card starts a new line after.
    private static let endsWithLineBreak = try! NSRegularExpression(
        pattern: #"(<br\s*/?>|</(div|p|li|ul|ol|h[1-6]|table|blockquote|pre)>)\s*$"#,
        options: [.caseInsensitive]
    )
}

/// A pasted picture made ready to store as media: upright, at most
/// `maxSide` pixels on its longest side, and a JPEG unless it has
/// see-through parts, which a JPEG would fill in black. A GIF is kept as it
/// is, so one that moves still does.
struct PreparedImage: Equatable, Sendable {
    let data: Data
    let fileExtension: String

    /// Sharp on any phone or tablet card, while a photo stays a few hundred
    /// KB rather than several MB.
    static let maxSide = 1600
    static let jpegQuality = 0.8

    /// Nil when the data isn't a picture this device can read.
    static func prepare(_ data: Data) -> PreparedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        if type?.conforms(to: .gif) == true {
            return PreparedImage(data: data, fileExtension: "gif")
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        let hasAlpha = properties[kCGImagePropertyHasAlpha as String] as? Bool ?? false

        // Already small and upright, in a format every card shows: keep it
        // exactly as it is rather than compress it again.
        if width > 0, height > 0, max(width, height) <= maxSide, orientation == 1 {
            if type?.conforms(to: .jpeg) == true { return PreparedImage(data: data, fileExtension: "jpg") }
            if type?.conforms(to: .png) == true { return PreparedImage(data: data, fileExtension: "png") }
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        let outputType: UTType = hasAlpha ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, outputType.identifier as CFString, 1, nil
        ) else { return nil }
        let encodeOptions: [CFString: Any] = hasAlpha
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PreparedImage(data: output as Data, fileExtension: hasAlpha ? "png" : "jpg")
    }
}
