//
//  TodaySummaryTests.swift
//  DecksFeatureTests
//

import Foundation
import Testing
import AnkiKit
import AnkiClients
import Dependencies
@testable import DecksFeature

@MainActor
@Suite struct TodaySummaryTests {

    @Test func theHardestAreTheMostForgottenThenTheMostReviewed() {
        let cards = [
            Self.card(1, lapses: 2, reps: 30),
            Self.card(2, lapses: 7, reps: 40),
            Self.card(3, lapses: 2, reps: 50),
            Self.card(4, lapses: 0, reps: 3),
            Self.card(5, lapses: 4, reps: 12),
            Self.card(6, lapses: 1, reps: 9),
        ]
        let hardest = TodaySummaryModel.hardest(cards)
        #expect(hardest.map(\.id.rawValue) == [2, 5, 3, 1, 6])
    }

    @Test func timeAndAccuracyReadPlainly() {
        #expect(TodaySummaryModel.duration(milliseconds: 20_000) == "under a minute")
        #expect(TodaySummaryModel.duration(milliseconds: 52 * 60_000) == "52 min")
        #expect(TodaySummaryModel.duration(milliseconds: 65 * 60_000) == "1 h 5 min")
        #expect(TodaySummaryModel.percent(176, of: 200) == "88%")
        #expect(TodaySummaryModel.percent(0, of: 0) == "–")
    }

    @Test func theSummaryListsTodaysMissedCardsAndSendsThemToTheGraveyard() async {
        let flagged = Flags()
        let missedToday = TodaySummaryModel.missedTodaySearch
        var cardClient = CardClient()
        cardClient.search = { query in
            query == missedToday ? [CardID(1), CardID(2)] : []
        }
        cardClient.fetch = { id in
            Self.card(id.rawValue, lapses: id.rawValue == 2 ? 6 : 1, reps: 10)
        }
        cardClient.flag = { id, flag in flagged.record(id, flag) }
        var noteClient = NoteClient()
        noteClient.fetch = { id in
            NoteRecord(id: id, guid: "g", mid: NotetypeID(1), mod: 0,
                       flds: "Card \(id.rawValue)<br>front\u{1f}back", sfld: "", csum: 0)
        }

        let model = withDependencies {
            $0.statsClient = StatsClient { _, _ in
                GraphsSnapshot(today: TodayCounts(answerCount: 200, answerMillis: 52 * 60_000, correctCount: 176))
            }
            $0.cardClient = cardClient
            $0.noteClient = noteClient
        } operation: {
            TodaySummaryModel()
        }

        await model.load()
        guard case .loaded(let summary) = model.state else {
            Issue.record("expected a loaded summary, got \(model.state)")
            return
        }
        #expect(summary.answers == 200 && summary.correct == 176)
        #expect(summary.hardest.map(\.cardId) == [CardID(2), CardID(1)], "most forgotten first")
        #expect(summary.hardest.first?.lapses == 6)
        #expect(model.selected == [CardID(1), CardID(2)], "all ticked to start with")

        model.selected.remove(CardID(1))
        await model.sendToGraveyard()
        #expect(flagged.all == ["2:1"], "only the ticked card, flagged red")
        #expect(model.sent == 1)
    }

    nonisolated static func card(_ id: Int64, lapses: Int32, reps: Int32) -> CardRecord {
        CardRecord(id: CardID(id), nid: NoteID(id), did: DeckID(1), mod: 0, type: 2, queue: 1, reps: reps, lapses: lapses)
    }
}

private final class Flags: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ id: CardID, _ flag: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        storage.append("\(id.rawValue):\(flag)")
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
