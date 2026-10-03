//
//  GraveyardModelTests.swift
//  GraveyardFeatureTests
//

import Foundation
import Testing
import AnkiKit
import AnkiClients
import Dependencies
@testable import GraveyardFeature

@MainActor
@Suite struct GraveyardModelTests {

    // MARK: - The list

    @Test func loadsEveryRedAndOrangeCardRedFirstUnderItsHomeDeck() async throws {
        let queries = Recorder<String>()
        let cards: [CardID: CardRecord] = [
            CardID(1): Self.card(1, note: 11, deck: 3, flags: 2),
            // In a filtered deck (5), home deck 4.
            CardID(2): Self.card(2, note: 12, deck: 5, homeDeck: 4, flags: 1),
            // Flag bits above the colour are ignored.
            CardID(3): Self.card(3, note: 13, deck: 3, flags: 0b1001),
        ]
        let notes: [NoteID: NoteRecord] = [
            NoteID(11): Self.note(11, ["Orange card", "back"]),
            NoteID(12): Self.note(12, ["<b>Red</b> card", "back"]),
            NoteID(13): Self.note(13, ["Another red", "back"]),
        ]

        let model = withDependencies {
            $0.cardClient.search = { query in
                queries.record(query)
                return [CardID(1), CardID(2), CardID(3)]
            }
            $0.cardClient.fetch = { id in cards[id]! }
            $0.noteClient.fetch = { id in notes[id] }
            $0.deckClient.fetchAll = {
                [DeckInfo(id: DeckID(3), name: "Peds"), DeckInfo(id: DeckID(4), name: "Neuro")]
            }
        } operation: {
            GraveyardModel()
        }
        await model.load()

        #expect(queries.all == ["flag:1 OR flag:2"])
        guard case .loaded(let items) = model.state else {
            Issue.record("expected loaded, got \(model.state)")
            return
        }
        #expect(items.map(\.cardId) == [CardID(2), CardID(3), CardID(1)], "red (Neuro, then Peds), then orange")
        #expect(items.map(\.flag) == [1, 1, 2])
        #expect(items[0].deckName == "Neuro", "a card in a filtered deck is shown under its home deck")
        #expect(items[0].front == "Red card", "HTML is stripped for the list")
    }

    @Test func aFailedSearchIsShownAsAFailure() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let model = withDependencies {
            $0.cardClient.search = { _ in throw Boom() }
            $0.deckClient.fetchAll = { [] }
        } operation: {
            GraveyardModel()
        }
        await model.load()
        #expect(model.state == .failed("boom"))
    }

    // MARK: - The conversation

    @Test func theConversationOpensWithACheckAndCanApplyTheFix() async throws {
        let sent = Recorder<[CardReviewMessage]>()
        let saved = Recorder<NoteRecord>()
        let original = Self.note(20, ["Dose of X?", "10 mg/kg", ""])
        let notetype = Self.basicWithExtra()
        let reply = #"{"reply": "The dose is 5 mg/kg.", "proposed_fields": [{"name": "Back", "value": "5 mg/kg"}]}"#

        let model = withDependencies {
            $0.cardReviewAI.send = { instructions, conversation in
                #expect(instructions.contains("Dose of X?"))
                sent.record(conversation)
                return reply
            }
            $0.noteClient.fetch = { _ in original }
            $0.noteClient.save = { note in saved.record(note) }
            $0.notetypesClient.get = { _ in notetype }
        } operation: {
            CardReviewChatModel(noteId: NoteID(20), deckName: "Peds")
        }

        await model.start()
        #expect(sent.all.first?.map(\.text) == [CardReviewPrompt.opening])
        #expect(model.messages.map(\.role) == [.user, .assistant])
        let answer = try #require(model.messages.last)
        #expect(answer.text == "The dose is 5 mg/kg.")
        #expect(answer.proposal == [ProposedField(name: "Back", value: "5 mg/kg")])

        await model.apply(answer)
        let written = try #require(saved.all.first)
        #expect(CardFieldEdits.splitFields(written.flds) == ["Dose of X?", "5 mg/kg", ""])
        #expect(model.applied.contains(answer.id))

        // A second tap doesn't write again.
        await model.apply(answer)
        #expect(saved.all.count == 1)
    }

    @Test func aFailedQuestionComesBackOffTheConversationForARetry() async {
        let attempts = Recorder<Int>()
        let model = withDependencies {
            $0.cardReviewAI.send = { _, _ in
                attempts.record(1)
                throw CardReviewError.noKey
            }
            $0.noteClient.fetch = { _ in Self.note(20, ["Q", "A"]) }
            $0.notetypesClient.get = { _ in Self.basicWithExtra() }
        } operation: {
            CardReviewChatModel(noteId: NoteID(20), deckName: "Peds")
        }

        await model.start()
        #expect(model.messages.isEmpty, "the unanswered question is taken back off")
        #expect(model.failedQuestion == CardReviewPrompt.opening)
        #expect(model.errorMessage == CardReviewError.noKey.errorDescription)

        await model.retry()
        #expect(attempts.all.count == 2)
    }

    // MARK: - Mark as Fixed

    private static let flagged = GraveyardItem(
        cardId: CardID(7), noteId: NoteID(70), flag: 2, front: "Q", deckName: "Peds"
    )

    @Test func aFixedCardStartsOverAsNewThenLosesItsFlag() async {
        let calls = Recorder<String>()
        let model = withDependencies {
            $0.cardClient.startOver = { id, restorePosition, resetCounts in
                calls.record("start over \(id.rawValue), restore position \(restorePosition), reset counts \(resetCounts)")
            }
            $0.cardClient.flag = { id, flag in calls.record("flag \(id.rawValue) \(flag)") }
        } operation: {
            GraveyardCardModel(item: Self.flagged)
        }

        #expect(await model.markFixed())
        #expect(calls.all == [
            "start over 7, restore position true, reset counts true",
            "flag 7 0",
        ])
    }

    @Test func aCardThatCouldntStartOverKeepsItsFlag() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let flags = Recorder<UInt32>()
        let model = withDependencies {
            $0.cardClient.startOver = { _, _, _ in throw Boom() }
            $0.cardClient.flag = { _, flag in flags.record(flag) }
        } operation: {
            GraveyardCardModel(item: Self.flagged)
        }

        #expect(await model.markFixed() == false)
        #expect(flags.all.isEmpty, "it stays in the Graveyard, to try again")
        #expect(model.errorMessage == "boom")
    }
}

// MARK: - Fixtures

// `nonisolated`: the stubbed clients call these from their @Sendable
// closures, off the suite's main actor.
private extension GraveyardModelTests {
    nonisolated static func card(
        _ id: Int64,
        note: Int64,
        deck: Int64,
        homeDeck: Int64 = 0,
        flags: Int32
    ) -> CardRecord {
        CardRecord(
            id: CardID(id), nid: NoteID(note), did: DeckID(deck), mod: 0,
            odid: DeckID(homeDeck), flags: flags
        )
    }

    nonisolated static func note(_ id: Int64, _ fields: [String]) -> NoteRecord {
        NoteRecord(
            id: NoteID(id), guid: "g\(id)", mid: NotetypeID(7), mod: 0,
            flds: fields.joined(separator: "\u{1f}"), sfld: fields.first ?? "", csum: 0
        )
    }

    nonisolated static func basicWithExtra() -> Notetype {
        Notetype(
            id: NotetypeID(7),
            name: "Basic",
            fields: [.init(name: "Front"), .init(name: "Back"), .init(name: "Extra")]
        )
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
