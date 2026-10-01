//
//  NotePasteTests.swift
//  BrowseFeatureTests
//

import AnkiClients
import AnkiKit
import CoreGraphics
import Dependencies
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BrowseFeature

@Suite struct NotePasteTests {

    // MARK: - Where it goes

    @Test func pastesGoWhereExtrasLive() {
        #expect(NotePaste.targetFieldIndex(fieldNames: ["Front", "Back", "Extra"], fieldCount: 3) == 2)
        #expect(NotePaste.targetFieldIndex(fieldNames: ["Text", "Back Extra"], fieldCount: 2) == 1)
        #expect(NotePaste.targetFieldIndex(fieldNames: ["Front", "Back"], fieldCount: 2) == 1)
        #expect(NotePaste.targetFieldIndex(fieldNames: ["Word", "Meaning", "Notes"], fieldCount: 3) == 2, "otherwise the last field")
    }

    @Test func aNoteWhoseFieldsHaventLoadedTakesNoPaste() {
        #expect(NotePaste.targetFieldIndex(fieldNames: ["Front", "Extra"], fieldCount: 0) == nil)
        #expect(NotePaste.targetFieldIndex(fieldNames: [], fieldCount: 3) == 2, "no names: the last field")
        #expect(NotePaste.targetFieldIndex(fieldNames: ["Front", "Back", "Extra"], fieldCount: 2) == 1, "never past the note's fields")
    }

    // MARK: - How it's written

    @Test func aPasteStartsOnALineOfItsOwn() {
        #expect(NotePaste.appending("new", to: "") == "new")
        #expect(NotePaste.appending("new", to: "  \n") == "new")
        #expect(NotePaste.appending("new", to: "old") == "old<br>new")
        #expect(NotePaste.appending("new", to: "old<br>") == "old<br>new", "already on a new line")
        #expect(NotePaste.appending("new", to: "old<BR />\n") == "old<BR />\nnew")
        #expect(NotePaste.appending("new", to: "<div>old</div>") == "<div>old</div>new", "a block ends its own line")
        #expect(NotePaste.appending("", to: "old") == "old")
    }

    @Test func pastedTextIsEscapedAndKeepsItsLineBreaks() {
        #expect(NotePaste.html(forText: "  Na < 135 & K\n\nthen\n") == "Na &lt; 135 &amp; K<br><br>then")
        #expect(NotePaste.html(forText: "\n \n").isEmpty)
    }

    @Test func aPictureIsNamedForItsContentAsAnkiNamesPastes() {
        let name = NotePaste.mediaFilename(for: Data("abc".utf8), fileExtension: "jpg")
        #expect(name == "paste-a9993e364706816aba3e25717850c26c9cd0d89d.jpg")
        #expect(NotePaste.imageTag(filename: name) == #"<img src="paste-a9993e364706816aba3e25717850c26c9cd0d89d.jpg">"#)
    }

    @Test func textIsReadAsUTF8() {
        #expect(NotePaste.decodedText(Data("héllo\0".utf8)) == "héllo")
    }

    // MARK: - Pictures

    @Test func aBigPhotoIsShrunkToAJPEG() throws {
        let photo = Self.encodedImage(width: 3200, height: 2000, type: .jpeg)
        let prepared = try #require(PreparedImage.prepare(photo))
        #expect(prepared.fileExtension == "jpg")
        let size = try #require(Self.pixelSize(of: prepared.data))
        #expect(max(size.width, size.height) <= PreparedImage.maxSide)
        #expect(size.width >= 1500 && size.width > size.height, "shrunk, not cropped")
    }

    @Test func aSmallJPEGIsKeptAsItIs() throws {
        let photo = Self.encodedImage(width: 200, height: 100, type: .jpeg)
        let prepared = try #require(PreparedImage.prepare(photo))
        #expect(prepared == PreparedImage(data: photo, fileExtension: "jpg"))
    }

    @Test func aPictureWithSeeThroughPartsStaysAPNG() throws {
        let diagram = Self.encodedImage(width: 2400, height: 1200, type: .png, transparent: true)
        let prepared = try #require(PreparedImage.prepare(diagram))
        #expect(prepared.fileExtension == "png", "a JPEG would fill the see-through parts in black")
        let size = try #require(Self.pixelSize(of: prepared.data))
        #expect(max(size.width, size.height) <= PreparedImage.maxSide)
    }

    @Test func aGIFIsKeptSoItStillMoves() throws {
        let gif = Self.encodedImage(width: 40, height: 40, type: .gif)
        let prepared = try #require(PreparedImage.prepare(gif))
        #expect(prepared == PreparedImage(data: gif, fileExtension: "gif"))
    }

    @Test func somethingThatIsntAPictureIsRefused() {
        #expect(PreparedImage.prepare(Data("not a picture".utf8)) == nil)
    }
}

// MARK: - The editor's Paste

@MainActor
@Suite struct NoteEditorPasteTests {

    @Test func textGoesOnTheEndOfExtra() async {
        let model = NoteEditorModel(note: Self.note)
        model.fieldNames = ["Front", "Back", "Extra"]
        model.fieldValues = ["Q", "A", "Seen in MG"]

        await model.paste([.text("Ptosis\nDiplopia")])

        #expect(model.fieldValues == ["Q", "A", "Seen in MG<br>Ptosis<br>Diplopia"])
        #expect(model.pasteCount == 1)
        #expect(model.pasteError == nil)
    }

    @Test func aPictureIsSavedAsMediaAndShownInExtra() async {
        let saved = Recorder<String>()
        let photo = NotePasteTests.encodedImage(width: 120, height: 80, type: .jpeg)
        let expectedName = NotePaste.mediaFilename(for: photo, fileExtension: "jpg")

        let model = withDependencies {
            $0.mediaClient.save = { _, filename in saved.record(filename) }
        } operation: {
            NoteEditorModel(note: Self.note)
        }
        model.fieldNames = ["Text", "Back Extra"]
        model.fieldValues = ["{{c1::Ptosis}}", ""]

        await model.paste([.image(photo), .text("from the lecture")])

        #expect(saved.all == [expectedName])
        #expect(model.fieldValues[1] == #"<img src="\#(expectedName)"><br>from the lecture"#)
        #expect(model.fieldValues[0] == "{{c1::Ptosis}}", "the other fields are left alone")
    }

    @Test func aPictureThatCantBeReadIsReportedAndNothingChanges() async {
        let model = NoteEditorModel(note: Self.note)
        model.fieldNames = ["Front", "Back"]
        model.fieldValues = ["Q", "A"]

        await model.paste([.image(Data("not a picture".utf8))])

        #expect(model.fieldValues == ["Q", "A"])
        #expect(model.pasteCount == 0)
        #expect(model.pasteError == "The picture couldn't be added.")
    }

    private static let note = NoteRecord(
        id: NoteID(1), guid: "g1", mid: NotetypeID(1), mod: 0, flds: "", sfld: "", csum: 0
    )
}

// MARK: - Fixtures

extension NotePasteTests {
    /// A picture of the given size and format, half filled with colour; with
    /// `transparent`, the other half see-through.
    static func encodedImage(width: Int, height: Int, type: UTType, transparent: Bool = false) -> Data {
        let alpha: CGImageAlphaInfo = transparent ? .premultipliedLast : .noneSkipLast
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue
        ) else { return Data() }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: transparent ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        guard let image = context.makeImage() else { return Data() }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, type.identifier as CFString, 1, nil
        ) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return output as Data
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int
        else { return nil }
        return (width, height)
    }
}

private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func record(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
