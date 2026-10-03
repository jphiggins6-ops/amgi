//
//  DeckListModel.swift
//  DecksFeature
//
//  Created by Vladimir Gusev on 13.06.2026.
//

import OSLog
import UI
import AppCore
import AppShared
import AnkiClients
import AnkiKit
import Dependencies
import Foundation
import ReviewFeature

/// Data state + load/mutation logic for the Library screen. Mirrors
/// `DeckDetailModel`: the View owns navigation, sheets, and the toolbar,
/// while the model owns I/O and the engine → view-data assembly so that
/// assembly is testable in isolation and the View stays a thin
/// presentation wiring layer.
@Observable
@MainActor
final class DeckListModel {
    var state: LibraryListContent.State = .loading

    @ObservationIgnored @Dependency(\.deckClient) private var deckClient
    @ObservationIgnored @Dependency(\.cardClient) private var cardClient
    @ObservationIgnored @Dependency(\.statsClient) private var statsClient
    @ObservationIgnored @Dependency(\.collectionStore) private var store

    /// Two phase, deliberately. The deck rows and the hero's due counts come
    /// straight from the deck tree; the streak, sparkline, and heatmap need a
    /// 365-day revlog scan. Publishing both together meant the primary content
    /// waited on the secondary — a blank screen at launch on a large
    /// collection. Rows go out first, activity fills in.
    func load() async {
        await AppSignpost.measure("DeckListLoad") { await loadBody() }
    }

    private func loadBody() async {
        // Carry the previous activity data through a refresh rather than
        // flashing placeholders over numbers that are still on screen.
        let carried: (hero: HeroData, heatmap: HeatmapCardData?)?
        if case .loaded(_, let hero, let heatmap) = state {
            carried = (hero, heatmap)
        } else {
            carried = nil
        }

        do {
            // Separates engine wait from Swift assembly. Phase one measured
            // 145 ms in-app but only 0.44 ms against stubbed clients
            // (DeckListLoadPerformanceTests), so the cost has to be in here —
            // and it is I/O-bound, which is why the CPU profile barely sees it.
            let tree = try await AppSignpost.measure("DeckTreeFetch") {
                try await store.tree()
            }
            if tree.isEmpty {
                state = .empty
                return
            }
            let rows = tree.map(DeckListRow.init(node:))
            let viewRows = rows.map(\.viewData)
            // The two study buttons: what's left of today, and of how many.
            let today = await todayProgress(tree: tree)
            let counts = HeroData(
                reviewCount: today.reviewsLeft,
                newCount: today.newLeft,
                reviewTotal: today.reviewsLeft + today.reviewsDone,
                newTotal: today.newLeft + today.newDone,
                againCount: today.dueAgain,
                streak: carried?.hero.streak ?? 0,
                last14Days: carried?.hero.last14Days ?? Array(repeating: 0, count: 14)
            )

            state = .loaded(rows: viewRows, hero: counts, heatmap: carried?.heatmap)

            // Nested inside DeckListLoad on purpose: phase one (the deck
            // tree) and phase two (a 365-day revlog scan) have very
            // different costs, and a single interval hides which one the
            // launch path is actually waiting on.
            let (hero, heatmap, rolloverHour) = await AppSignpost.measure("DeckListActivity") {
                await buildHeroAndHeatmap(counts: counts)
            }
            guard !Task.isCancelled else { return }
            state = .loaded(rows: viewRows, hero: hero, heatmap: heatmap)
            writeTodayWidget(Self.todaySnapshot(today, rolloverHour: rolloverHour, now: Date()))
        } catch {
            Log.decks.error("Error loading decks: \(error)")
            // NOT .empty — that is the genuine no-decks state, and rendering a
            // failure as it told users with a full collection they had none.
            state = .failed(error.localizedDescription)
        }
    }

    func delete(_ id: DeckID) async {
        do {
            let changes = try await deckClient.delete(id)
            store.apply(changes)   // generation bump → the view's .task(id:) reloads
        } catch {
            Log.decks.error("Delete failed: \(error)")
            await load()           // error path: no invalidation happened, reload manually
        }
    }

    /// What the Library's two study buttons gather. Each is a round that
    /// shows every card in it once (`StudyRound`); today's minimum is the
    /// first two.
    enum StudyNowKind: Sendable {
        /// Every card that is due, has no flag, isn't in deck "p", and
        /// hasn't been answered yet today.
        case reviews
        /// Today's new cards from every deck but "p", within each deck's
        /// daily new-card limit.
        case newCards
        /// Cards answered today that are due again: the Reviews button's
        /// round once every due card has had its turn.
        case again
    }

    /// Where today stands. Every number comes from the collection, so it
    /// survives leaving a round half done, a restart, or study on another
    /// device, and resets with Anki's day.
    struct TodayProgress: Equatable, Sendable {
        /// Due cards not yet answered today.
        var reviewsLeft = 0
        /// Cards answered today that weren't new: today's reviews done.
        /// Answered cards stay counted however soon they're due again, so
        /// done plus left is fixed for the day.
        var reviewsDone = 0
        /// New cards left today, within each deck's limit.
        var newLeft = 0
        /// New cards learned today.
        var newDone = 0
        /// Cards answered today that are due again.
        var dueAgain = 0
    }

    func todayProgress(tree: [DeckTreeNode]) async -> TodayProgress {
        let reviewsLeft = await count(Self.gatherable(Self.reviewsRoundSearch))
        let reviewsDone = await count(Self.reviewsDoneTodaySearch)
        let newDone = await count(Self.newCardsLearnedTodaySearch)
        let dueAgain = await count(Self.gatherable(Self.dueAgainSearch))
        return TodayProgress(
            reviewsLeft: reviewsLeft,
            reviewsDone: reviewsDone,
            newLeft: Self.newCardsToday(in: tree),
            newDone: newDone,
            dueAgain: dueAgain
        )
    }

    /// Every due card seen once today and today's new cards learned.
    func isDoneForToday() async -> Bool {
        let tree = (try? await deckClient.fetchTree()) ?? []
        let today = await todayProgress(tree: tree)
        return today.reviewsLeft == 0 && today.newLeft == 0
    }

    /// The Today widget's copy of `today`.
    static func todaySnapshot(_ today: TodayProgress, rolloverHour: Int, now: Date) -> TodaySnapshot {
        TodaySnapshot(
            reviewsLeft: today.reviewsLeft,
            reviewsTotal: today.reviewsLeft + today.reviewsDone,
            newLeft: today.newLeft,
            newTotal: today.newLeft + today.newDone,
            dueAgain: today.dueAgain,
            dayStart: AnkiDay.start(of: now, rolloverHour: rolloverHour),
            rolloverHour: rolloverHour
        )
    }

    private func count(_ search: String) async -> Int {
        (try? await cardClient.search(search).count) ?? 0
    }

    /// A study button's session: the Study Now deck it built and the round
    /// the deck holds.
    struct StudyNowLaunch: Identifiable, Equatable {
        let deckId: DeckID
        let round: StudyRound

        var id: Int64 { deckId.rawValue }
    }

    enum StudyButton: Sendable {
        case reviews
        case newCards
    }

    /// Builds the round a study button opens. Reviews opens today's first
    /// look at every due card while any are left, and after that another
    /// look at the cards due again.
    func prepareStudyNow(_ button: StudyButton) async throws -> StudyNowLaunch {
        let tree = (try? await deckClient.fetchTree()) ?? []
        let today = await todayProgress(tree: tree)
        switch button {
        case .reviews where today.reviewsLeft > 0:
            let deckId = try await buildStudyNowDeck(.reviews)
            return StudyNowLaunch(deckId: deckId, round: StudyRound(
                kind: .reviews,
                doneEarlierToday: today.reviewsDone,
                finishesTheDay: today.newLeft == 0
            ))
        case .reviews:
            guard today.dueAgain > 0 else { throw StudyNowError.nothingDue }
            let deckId = try await buildStudyNowDeck(.again)
            return StudyNowLaunch(deckId: deckId, round: StudyRound(kind: .again))
        case .newCards:
            let deckId = try await buildStudyNowDeck(.newCards)
            return StudyNowLaunch(deckId: deckId, round: StudyRound(
                kind: .newCards,
                doneEarlierToday: today.newDone,
                finishesTheDay: today.reviewsLeft == 0
            ))
        }
    }

    /// Both study buttons build this one filtered deck, rebuilt in place on
    /// each tap and emptied when the session closes (`finishStudyNow`). One
    /// deck rather than two: a card still in its learning steps stays in
    /// the filtered deck it was answered in, and a deck gathers nothing
    /// that another filtered deck holds, so a second deck would strand
    /// cards where the other button can't reach them.
    ///
    /// Gathered in random order. The engine numbers the cards in gather
    /// order as they enter a filtered deck and serves them by that number,
    /// so the session is shuffled, decks mixed together, afresh on every
    /// tap. `reschedule: true` means answers count exactly as they would in
    /// the card's home deck — the engine schedules with the home deck's
    /// preset (FSRS parameters, steps, retention).
    static let studyNowDeckName = "Study Now"
    /// Today's first look: due, unflagged, outside "p", not yet answered
    /// today. A card missed today waits for the `again` round, however
    /// soon it's due, which is also why the count of what's left never
    /// grows back.
    static let reviewsRoundSearch = "is:due flag:0 -deck:p -rated:1"
    /// Cards answered today that are due again.
    static let dueAgainSearch = "rated:1 is:due flag:0 -deck:p"
    /// Today's reviews done: answered today and not new this morning,
    /// whatever their flag now.
    static let reviewsDoneTodaySearch = "rated:1 -introduced:1 -deck:p"
    /// Today's new cards done: first answered today.
    static let newCardsLearnedTodaySearch = "introduced:1 -deck:p"

    /// Counts what `search` would gather right now. Gathering skips cards
    /// held by other filtered decks, but only after returning Study Now's
    /// own cards home, so those still count.
    static func gatherable(_ search: String) -> String {
        "\(search) (-deck:filtered OR \"deck:\(studyNowDeckName)\")"
    }

    func buildStudyNowDeck(_ kind: StudyNowKind) async throws -> DeckID {
        switch kind {
        case .reviews:
            return try await buildGatheredDeck(Self.reviewsRoundSearch)
        case .again:
            return try await buildGatheredDeck(Self.dueAgainSearch)
        case .newCards:
            return try await buildNewCardsDeck()
        }
    }

    /// Returns whatever a session left in Study Now to the cards' home
    /// decks, progress kept, so both counts read off the home decks and no
    /// card waits in a deck neither button shows.
    func finishStudyNow(_ deckId: DeckID) async {
        do {
            try await deckClient.emptyFilteredDeck(deckId)
        } catch {
            Log.decks.error("Emptying Study Now failed: \(error)")
        }
        store.invalidateAll()
    }

    private func buildGatheredDeck(_ search: String) async throws -> DeckID {
        let tree = (try? await deckClient.fetchTree()) ?? []
        let existing = FilteredDeckPresetsModel.filteredDecksByName(tree)[Self.studyNowDeckName]
        let spec = FilteredDeckSpec(
            id: existing?.id ?? DeckID(0),
            name: Self.studyNowDeckName,
            searchTerms: [
                // The limit is above any real due count, so the random order
                // never decides which cards are left out.
                FilteredDeckSearchTerm(search: search, limit: 9999, order: .random)
            ],
            reschedule: true
        )
        let creation = try await deckClient.createFilteredDeck(spec)
        store.apply(creation.changes)
        return creation.id
    }

    /// A filtered deck ignores deck limits, so today's new cards are picked
    /// from each deck's own queue — its daily limit, gather order, and
    /// sibling burying, exactly as studying the deck would hand them out —
    /// and then gathered by id. The session's `ReviewView` charges them back
    /// to those limits (`countsNewCardsAgainstHomeDecks`), which the engine
    /// would otherwise credit to Study Now.
    private func buildNewCardsDeck() async throws -> DeckID {
        var tree = try await deckClient.fetchTree()
        let existing = FilteredDeckPresetsModel.filteredDecksByName(tree)[Self.studyNowDeckName]
        if let existing {
            // Anything an unfinished session left goes home first, so its
            // unstudied new cards are back in their decks' queues.
            try await deckClient.emptyFilteredDeck(existing.id)
            tree = try await deckClient.fetchTree()
        }

        var picked: [CardID] = []
        for deck in tree where Self.offersNewCards(deck) {
            // Queue 0 is Anki's new queue. The limit covers the whole queue:
            // new cards can sit behind reviews.
            let queue = try await cardClient.fetchQueue(deck.id, deck.counts.total)
            picked += queue.filter { $0.queue == 0 }.map(\.id)
        }
        guard !picked.isEmpty else { throw StudyNowError.noNewCards }

        let spec = FilteredDeckSpec(
            id: existing?.id ?? DeckID(0),
            name: Self.studyNowDeckName,
            searchTerms: [
                FilteredDeckSearchTerm(search: Self.cardIDSearch(picked), limit: picked.count, order: .random)
            ],
            reschedule: true
        )
        let creation = try await deckClient.createFilteredDeck(spec)
        store.apply(creation.changes)
        return creation.id
    }

    /// A top-level deck the New button draws from: not a filtered deck
    /// (Study Now included), not "p", and with new cards left today.
    static func offersNewCards(_ deck: DeckTreeNode) -> Bool {
        !deck.isFiltered
            && deck.name.caseInsensitiveCompare("p") != .orderedSame
            && deck.counts.newCount > 0
    }

    /// The New button's count: new cards left today, per each deck's limit,
    /// across the decks it draws from. A parent's count already includes
    /// its subdecks, so only top-level decks are summed.
    static func newCardsToday(in tree: [DeckTreeNode]) -> Int {
        tree.filter(offersNewCards).reduce(0) { $0 + $1.counts.newCount }
    }

    static func cardIDSearch(_ ids: [CardID]) -> String {
        "cid:" + ids.map { String($0.rawValue) }.joined(separator: ",")
    }

    enum StudyNowError: LocalizedError, Equatable {
        case noNewCards
        case nothingDue

        var errorDescription: String? {
            switch self {
            case .noNewCards: "There are no new cards left for today."
            case .nothingDue: "Every card due today has had its turn. Cards you've seen come back here as they fall due again."
            }
        }
    }

    static func buildHeatmap(
        reviews: [Int: ReviewCountsAndTimes.Reviews]
    ) -> HeatmapCardData {
        var counts = [Int: Int](minimumCapacity: min(reviews.count, 365))
        var maxCount = 1
        for (offset, rev) in reviews where offset >= -364 && offset <= 0 {
            let total = rev.learn + rev.relearn + rev.young + rev.mature + rev.filtered
            if total > 0 {
                counts[offset] = total
                if total > maxCount { maxCount = total }
            }
        }
        return HeatmapCardData(counts: counts, maxCount: maxCount)
    }
}

private extension DeckListModel {
    /// Also returns Anki's day-boundary hour, which the graphs carry: 4 am
    /// (Anki's default) when they can't be fetched.
    func buildHeroAndHeatmap(counts: HeroData) async -> (HeroData, HeatmapCardData, Int) {
        // Window the streak over the same range we fetch, or the default
        // 28 silently caps a year's worth of data at 28 days.
        let graphDays = 365
        guard let graphs = try? await statsClient.fetchGraphs("", graphDays) else {
            return (
                counts.withActivity(streak: 0, last14Days: Array(repeating: 0, count: 14)),
                HeatmapCardData.empty,
                4
            )
        }
        let reviewCounts = graphs.reviews.count
        let hero = counts.withActivity(
            streak: StreakCalculator.streak(reviews: reviewCounts, window: graphDays),
            last14Days: StreakCalculator.lastNDaysTotals(reviews: reviewCounts, days: 14)
        )
        return (hero, Self.buildHeatmap(reviews: reviewCounts), graphs.rolloverHour)
    }
}
