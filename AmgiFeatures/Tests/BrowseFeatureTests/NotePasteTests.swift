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

    @Test func aPicturePastedIntoPlainTextGoesWhereTheCursorIs() {
        let tag = NotePaste.imageTag(filename: "a.png")
        let pasted = NotePaste.inserting(tag, intoPlainText: "Hello\nworld", replacing: NSRange(location: 5, length: 0))
        #expect(pasted.stored == "Hello<img src=\"a.png\"><br>world")
        #expect(pasted.display == "Hello<img src=\"a.png\"><br>\nworld", "shown as HTML from now on")
        #expect(pasted.caret == ("Hello" + tag as NSString).length, "the cursor just after the picture")
    }

    @Test func aPicturePastedOverASelectionReplacesIt() {
        let pasted = NotePaste.inserting("<img src=\"b.jpg\">", intoPlainText: "a < b, c", replacing: NSRange(location: 4, length: 1))
        #expect(pasted.stored == "a &lt; <img src=\"b.jpg\">, c", "the rest still escaped as typed text")
    }

    @Test func aCursorPastTheEndPastesAtTheEnd() {
        let pasted = NotePaste.inserting("<img src=\"c.gif\">", intoPlainText: "end", replacing: NSRange(location: NSNotFound, length: 0))
        #expect(pasted.stored == "end<img src=\"c.gif\">")
        #expect(pasted.caret == (pasted.display as NSString).length)
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

// MARK: - Cloze deletions

@Suite struct ClozeEditingTests {
    @Test func aSelectionBecomesTheNextCard() {
        let text = "The capital of France is Paris"
        let first = ClozeEditing.wrapping(NSRange(location: 25, length: 5), in: text, number: ClozeEditing.nextNumber(in: text))
        let once = applied(first, to: text)
        #expect(once == "The capital of France is {{c1::Paris}}")
        #expect(first.selection == NSRange(location: 38, length: 0), "the cursor after it")
        let second = ClozeEditing.wrapping(NSRange(location: 15, length: 6), in: once, number: ClozeEditing.nextNumber(in: once))
        #expect(applied(second, to: once) == "The capital of {{c2::France}} is {{c1::Paris}}")
    }

    @Test func sameCardUsesTheHighestNumber() {
        let text = "{{c1::a}} {{c2::b}} c"
        #expect(ClozeEditing.highestNumber(in: text) == 2)
        #expect(ClozeEditing.nextNumber(in: text) == 3)
        #expect(ClozeEditing.highestNumber(in: "none yet") == 1)
        #expect(ClozeEditing.nextNumber(in: "none yet") == 1)
    }

    @Test func spacesAtTheEndsOfASelectionStayOutside() {
        let edit = ClozeEditing.wrapping(NSRange(location: 3, length: 5), in: "abc def gh", number: 2)
        #expect(applied(edit, to: "abc def gh") == "abc {{c2::def}} gh")
    }

    @Test func nothingSelectedMakesAnEmptyOneToTypeInto() {
        let edit = ClozeEditing.wrapping(NSRange(location: 3, length: 0), in: "abc def", number: 1)
        #expect(applied(edit, to: "abc def") == "abc{{c1::}} def")
        #expect(edit.selection == NSRange(location: 9, length: 0), "the cursor inside")
    }

    @Test func theDeletionTheCursorIsInMovesToAnotherCard() throws {
        let text = "The capital of {{c2::France}} is {{c1::Paris}}"
        let caret = NSRange(location: 29, length: 0)
        let cloze = try #require(ClozeEditing.cloze(at: caret, in: text), "just after its braces counts")
        #expect(cloze.number == 2)
        let edit = ClozeEditing.renumbering(cloze, to: 3, keeping: caret)
        #expect(applied(edit, to: text) == "The capital of {{c3::France}} is {{c1::Paris}}")
        #expect(edit.selection == caret)
    }

    @Test func theCursorJustBeforeADeletionIsntInIt() {
        #expect(ClozeEditing.cloze(at: NSRange(location: 0, length: 0), in: "{{c1::x}}") == nil)
        #expect(ClozeEditing.cloze(at: NSRange(location: 9, length: 0), in: "{{c1::x}}")?.number == 1)
    }

    @Test func theInnermostDeletionIsTheOneChanged() {
        let text = "{{c1::outer {{c2::inner}} end}}"
        #expect(ClozeEditing.cloze(at: NSRange(location: 20, length: 0), in: text)?.number == 2)
        #expect(ClozeEditing.cloze(at: NSRange(location: 8, length: 0), in: text)?.number == 1)
    }

    @Test func unwrapKeepsTheWordsAndDropsTheHint() throws {
        let text = "{{c1::Na::ion}} and {{c2::K}}"
        let cloze = try #require(ClozeEditing.cloze(at: NSRange(location: 8, length: 0), in: text))
        #expect(cloze.hintRange == NSRange(location: 10, length: 3))
        #expect(applied(ClozeEditing.removing(cloze, in: text), to: text) == "Na and {{c2::K}}")
    }

    @Test func hintMakesRoomForOneOrSelectsIt() throws {
        let text = "{{c1::Paris}}"
        let cloze = try #require(ClozeEditing.cloze(at: NSRange(location: 13, length: 0), in: text))
        let edit = ClozeEditing.hint(for: cloze)
        #expect(applied(edit, to: text) == "{{c1::Paris::}}")
        #expect(edit.selection == NSRange(location: 13, length: 0))
        let hinted = "{{c1::Paris::city}}"
        let withHint = try #require(ClozeEditing.cloze(at: NSRange(location: 8, length: 0), in: hinted))
        #expect(ClozeEditing.hint(for: withHint).selection == NSRange(location: 13, length: 4), "the hint there, selected")
    }

    @Test func renumberPutsThemInOrderWithoutGaps() {
        let edit = ClozeEditing.renumberedInOrder("{{c3::a}} {{c1::b}} {{c3::c}}", keeping: NSRange(location: 28, length: 0))
        #expect(edit?.replacement == "{{c1::a}} {{c2::b}} {{c1::c}}")
        #expect(ClozeEditing.renumberedInOrder("{{c1::a}} {{c2::b}}", keeping: NSRange(location: 0, length: 0)) == nil, "already in order")
    }

    @Test func eachCardNumberIsCountedOnce() {
        #expect(ClozeEditing.numbers(in: "{{c2::a}} {{c1::b}} {{c2::c}} {{c10::d}}") == [1, 2, 10])
        #expect(ClozeEditing.numbers(in: "{{c::x}} {c1::y} plain").isEmpty, "not deletions")
    }

    @Test func theClozeFieldIsTheOneItsTemplateReadsWithTheClozeFilter() {
        let fields = ["Text", "Back Extra"]
        #expect(NotetypeInfo.clozeFieldNames(in: ["{{cloze:Text}}"], fieldNames: fields) == ["Text"])
        #expect(NotetypeInfo.clozeFieldNames(
            in: ["{{#Back Extra}}{{Back Extra}}{{/Back Extra}} {{type:cloze:Text}}"],
            fieldNames: fields
        ) == ["Text"])
        #expect(NotetypeInfo.clozeFieldNames(in: ["{{Text}}"], fieldNames: fields).isEmpty)
        #expect(NotetypeInfo.clozeFieldNames(in: ["{{ cloze : Back Extra }}"], fieldNames: fields) == ["Back Extra"])
    }

    private func applied(_ edit: ClozeEditing.Edit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }
}
