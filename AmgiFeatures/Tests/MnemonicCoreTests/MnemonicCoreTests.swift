//
//  MnemonicCoreTests.swift
//  MnemonicCoreTests
//

import Foundation
import Testing
import AnkiKit
@testable import MnemonicCore

private let extraFields = ["Front", "Back", "Extra"]

private func makeNote(_ fields: [String], tags: String = "") -> NoteRecord {
    NoteRecord(
        id: NoteID(42),
        guid: "guid",
        mid: NotetypeID(7),
        mod: 0,
        tags: tags,
        flds: fields.joined(separator: "\u{1f}"),
        sfld: fields.first ?? "",
        csum: 0
    )
}

private func fields(_ note: NoteRecord) -> [String] {
    MnemonicNoteEditor.splitFields(note.flds)
}

private func tags(_ note: NoteRecord) -> [String] {
    MnemonicNoteEditor.tagList(note.tags)
}

private extension MnemonicNoteEditor.Outcome {
    var note: NoteRecord? {
        if case .updated(let note) = self { return note }
        return nil
    }
}

// MARK: - Markers

@Suite struct MnemonicMarkerTests {
    @Test(arguments: [
        "plain",
        "a-->b",
        "50% off -- really",
        "line1\nline2\r\nline3",
        "émoji 🧊 anchor",
        "<b>bold</b> & more",
        "a:b:c",
        "%2D stays literal",
    ])
    func encodingRoundTripsAndCanNeverCloseTheComment(_ text: String) {
        let encoded = MnemonicMarker.encode(text)
        #expect(MnemonicMarker.decode(encoded) == text)
        #expect(!encoded.contains("-"))
        #expect(!encoded.contains(">"))
    }

    @Test func findsEveryPendingMarkerWithItsIdea() {
        let text = "Existing extra."
            + MnemonicMarker.pending(id: "abc123", idea: "ice anchor -> huge")
            + " more text "
            + MnemonicMarker.pending(id: "def456", idea: "second")
        let found = MnemonicMarker.pendingMarkers(in: text)
        #expect(found.map(\.id) == ["abc123", "def456"])
        #expect(found.map(\.idea) == ["ice anchor -> huge", "second"])
    }

    @Test func approvedPicturesAreNotPending() {
        let text = MnemonicMarker.doneBlock(id: "abc123", prompt: "p", mediaFilename: "f.png")
        #expect(MnemonicMarker.pendingMarkers(in: text).isEmpty)
        #expect(MnemonicMarker.containsDone(id: "abc123", in: text))
        #expect(!MnemonicMarker.containsDone(id: "abc12", in: text), "an ID prefix must not count as a match")
    }

    @Test func newIDsAreShortLowercaseHex() {
        let id = MnemonicMarker.newID()
        #expect(id.count == 10)
        #expect(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}

// MARK: - Note rewrites

@Suite struct MnemonicNoteEditorTests {
    @Test func picksExtraThenBackExtraThenBackThenTheLastField() {
        #expect(MnemonicNoteEditor.targetFieldIndex(fieldNames: ["Front", "Back", "Extra"]) == 2)
        #expect(MnemonicNoteEditor.targetFieldIndex(fieldNames: ["Text", "Back Extra"]) == 1)
        #expect(MnemonicNoteEditor.targetFieldIndex(fieldNames: ["Front", "Back"]) == 1)
        #expect(MnemonicNoteEditor.targetFieldIndex(fieldNames: ["Front", "Notes", "Source"]) == 2)
        #expect(
            MnemonicNoteEditor.targetFieldIndex(fieldNames: ["front", "EXTRA", "back"]) == 1,
            "matching ignores case, and Extra outranks Back"
        )
        #expect(MnemonicNoteEditor.targetFieldIndex(fieldNames: []) == 0)
    }

    @Test func captureAppendsToExtraAndTagsTheNote() {
        let note = makeNote(["Q", "A", "Existing extra"], tags: "physics")
        let captured = MnemonicNoteEditor.capturing(
            idea: "ice anchor", markerId: "m1", in: note, fieldNames: extraFields
        )
        let f = fields(captured)
        #expect(f[0] == "Q")
        #expect(f[1] == "A")
        #expect(f[2] == "Existing extra" + MnemonicMarker.pending(id: "m1", idea: "ice anchor"))
        #expect(tags(captured) == ["physics", MnemonicNoteEditor.pendingTag])
    }

    @Test func captureFillsInMissingTrailingFields() {
        let captured = MnemonicNoteEditor.capturing(
            idea: "x", markerId: "m1", in: makeNote(["Q"]), fieldNames: extraFields
        )
        let f = fields(captured)
        #expect(f.count == 3)
        #expect(f[2] == MnemonicMarker.pending(id: "m1", idea: "x"))
    }

    @Test func twoIdeasOnOneNoteShareOneTag() {
        var note = makeNote(["Q", "A", ""])
        note = MnemonicNoteEditor.capturing(idea: "first", markerId: "m1", in: note, fieldNames: extraFields)
        note = MnemonicNoteEditor.capturing(idea: "second", markerId: "m2", in: note, fieldNames: extraFields)
        #expect(tags(note).filter { $0 == MnemonicNoteEditor.pendingTag }.count == 1)

        let items = MnemonicNoteEditor.pendingItems(in: note, fieldNames: extraFields)
        #expect(items.map(\.markerId) == ["m1", "m2"])
        #expect(items.map(\.idea) == ["first", "second"])
    }

    @Test func pendingItemsCarryTheirFieldAndAPlainCardSummary() throws {
        let note = MnemonicNoteEditor.capturing(
            idea: "power plant",
            markerId: "m1",
            in: makeNote(["<b>Mitochondria</b> make &amp; store ATP", "", ""]),
            fieldNames: extraFields
        )
        let item = try #require(MnemonicNoteEditor.pendingItems(in: note, fieldNames: extraFields).first)
        #expect(item.fieldName == "Extra")
        #expect(item.cardSummary == "Mitochondria make & store ATP")
        #expect(item.noteId == NoteID(42))
    }

    @Test func approvingSwapsTheIdeaForThePictureAndRetags() throws {
        let captured = MnemonicNoteEditor.capturing(
            idea: "ice anchor",
            markerId: "m1",
            in: makeNote(["Q", "A", "Extra text"], tags: "physics"),
            fieldNames: extraFields
        )
        let approved = try #require(MnemonicNoteEditor.approving(
            markerId: "m1",
            prompt: "ice anchor, huge",
            mediaFilename: "amgi-mnemonic-42-m1.png",
            in: captured
        ).note)

        let extra = fields(approved)[2]
        #expect(extra == "Extra text" + MnemonicMarker.doneBlock(
            id: "m1", prompt: "ice anchor, huge", mediaFilename: "amgi-mnemonic-42-m1.png"
        ))
        #expect(extra.contains("<img src=\"amgi-mnemonic-42-m1.png\""))
        #expect(MnemonicMarker.pendingMarkers(in: extra).isEmpty)
        #expect(tags(approved) == ["physics", MnemonicNoteEditor.doneTag])
    }

    @Test func thePendingTagStaysWhileAnotherIdeaWaits() throws {
        var note = makeNote(["Q", "A", ""])
        note = MnemonicNoteEditor.capturing(idea: "first", markerId: "m1", in: note, fieldNames: extraFields)
        note = MnemonicNoteEditor.capturing(idea: "second", markerId: "m2", in: note, fieldNames: extraFields)

        let approved = try #require(MnemonicNoteEditor.approving(
            markerId: "m1", prompt: "first", mediaFilename: "a.png", in: note
        ).note)
        #expect(tags(approved).contains(MnemonicNoteEditor.pendingTag))
        #expect(tags(approved).contains(MnemonicNoteEditor.doneTag))
        #expect(MnemonicNoteEditor.pendingItems(in: approved, fieldNames: extraFields).map(\.markerId) == ["m2"])
    }

    /// A retry after an approval that did land must not add the picture twice.
    @Test func approvingTwiceIsANoOp() throws {
        let captured = MnemonicNoteEditor.capturing(
            idea: "x", markerId: "m1", in: makeNote(["Q", "A", ""]), fieldNames: extraFields
        )
        let approved = try #require(MnemonicNoteEditor.approving(
            markerId: "m1", prompt: "x", mediaFilename: "a.png", in: captured
        ).note)
        #expect(MnemonicNoteEditor.approving(
            markerId: "m1", prompt: "x", mediaFilename: "a.png", in: approved
        ) == .alreadyApplied)
    }

    /// The stale-snapshot case: the note is edited between capture and
    /// approval (say, on another device). Approval works on the note as it
    /// is now, so the edit survives alongside the picture.
    @Test func approvalKeepsEditsMadeAfterCapture() throws {
        let captured = MnemonicNoteEditor.capturing(
            idea: "ice anchor", markerId: "m1", in: makeNote(["Q", "A", "Old fact."]), fieldNames: extraFields
        )
        var f = fields(captured)
        f[2] = f[2].replacingOccurrences(of: "Old fact.", with: "Old fact. New fact added later.")
        let current = MnemonicNoteEditor.withFields(f, in: captured)

        let approved = try #require(MnemonicNoteEditor.approving(
            markerId: "m1", prompt: "ice anchor", mediaFilename: "a.png", in: current
        ).note)
        let extra = fields(approved)[2]
        #expect(extra.hasPrefix("Old fact. New fact added later."))
        #expect(extra.contains("<img src=\"a.png\""))
    }

    @Test func approvingAnIdeaThatIsGoneSaysSo() {
        #expect(MnemonicNoteEditor.approving(
            markerId: "m1", prompt: "p", mediaFilename: "a.png", in: makeNote(["Q", "A", "no ideas here"])
        ) == .markerMissing)
    }

    @Test func discardingRemovesTheIdeaAndTheTag() throws {
        let captured = MnemonicNoteEditor.capturing(
            idea: "x", markerId: "m1", in: makeNote(["Q", "A", "Keep me"], tags: "physics"), fieldNames: extraFields
        )
        let discarded = try #require(MnemonicNoteEditor.discarding(markerId: "m1", in: captured).note)
        #expect(fields(discarded)[2] == "Keep me")
        #expect(tags(discarded) == ["physics"])
    }

    @Test func updatingAnIdeaKeepsItsID() throws {
        let captured = MnemonicNoteEditor.capturing(
            idea: "rough", markerId: "m1", in: makeNote(["Q", "A", ""]), fieldNames: extraFields
        )
        let updated = try #require(MnemonicNoteEditor.updatingIdea(
            markerId: "m1", to: "polished -> better", in: captured
        ).note)
        let items = MnemonicNoteEditor.pendingItems(in: updated, fieldNames: extraFields)
        #expect(items.map(\.markerId) == ["m1"])
        #expect(items.map(\.idea) == ["polished -> better"])
    }

    @Test func mediaFilenamesAreUniquePerNoteAndIdea() {
        #expect(MnemonicNoteEditor.mediaFilename(
            noteId: NoteID(42), markerId: "m1", fileExtension: "png"
        ) == "amgi-mnemonic-42-m1.png")
    }
}

// MARK: - Text

@Suite struct MnemonicTextTests {
    @Test func summaryShowsClozeAnswersAndDropsMarkup() {
        let html = "The {{c1::mitochondria::organelle}} is the <i>powerhouse</i>&nbsp;[sound:x.mp3]<br>of the cell"
        #expect(MnemonicText.summary(html) == "The mitochondria is the powerhouse of the cell")
    }

    @Test func summaryHidesMnemonicMarkers() {
        let html = "Front" + MnemonicMarker.pending(id: "m1", idea: "hidden idea")
        #expect(MnemonicText.summary(html) == "Front")
    }

    @Test func summaryTruncatesWithAnEllipsis() {
        let summary = MnemonicText.summary(String(repeating: "word ", count: 100), limit: 20)
        #expect(summary.count == 20)
        #expect(summary.hasSuffix("…"))
    }
}

// MARK: - The image hook

@Suite struct MnemonicImageTests {
    @Test func fullPromptWrapsTheIdeaInTheHouseStyle() {
        let request = MnemonicImageRequest(idea: "ice anchor")
        #expect(request.fullPrompt.hasPrefix(MnemonicPromptStyle.default))
        #expect(request.fullPrompt.hasSuffix("Scene: ice anchor"))
        #expect(MnemonicImageRequest(idea: "x", style: "").fullPrompt == "x")
    }

    #if canImport(UIKit)
    @Test func placeholderRendersAPNG() async throws {
        let data = try await PlaceholderImageRenderer.render(caption: "ice anchor", hue: 0.5)
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    @Test func placeholderGeneratorProducesAPNGFile() async throws {
        let image = try await MnemonicImageGenerator.placeholder.generate(MnemonicImageRequest(idea: "x"))
        #expect(image.fileExtension == "png")
        #expect(!image.data.isEmpty)
    }
    #endif
}
