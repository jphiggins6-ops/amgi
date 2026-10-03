//
//  TodaySnapshotTests.swift
//  AppCoreTests
//

import Foundation
import Testing
@testable import AppCore

@Suite struct TodaySnapshotTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ day: Int, _ hour: Int) -> Date {
        DateComponents(calendar: calendar, year: 2026, month: 10, day: day, hour: hour).date!
    }

    /// Written at noon on the 10th; Anki's day runs 4 am to 4 am.
    private func today(reviewsLeft: Int = 120, newLeft: Int = 8, dueAgain: Int = 0) -> TodaySnapshot {
        TodaySnapshot(
            reviewsLeft: reviewsLeft,
            reviewsTotal: 300,
            newLeft: newLeft,
            newTotal: 20,
            dueAgain: dueAgain,
            dayStart: date(10, 4),
            rolloverHour: 4
        )
    }

    @Test func doneOnceBothAreFinished() {
        #expect(!today().isDone)
        #expect(!today(reviewsLeft: 0).isDone, "new cards still left")
        #expect(today(reviewsLeft: 0, newLeft: 0).isDone)
    }

    @Test func fractionDoneCountsBothHalves() {
        #expect(abs(today().fractionDone - 192.0 / 320.0) < 0.0001)
        #expect(today(reviewsLeft: 0, newLeft: 0).fractionDone == 1)
    }

    @Test func todaysNumbersHoldUntilTheRollover() {
        let snapshot = today()
        #expect(TodayWidgetState.at(date(10, 23), today: snapshot, forecast: nil, calendar: calendar) == .progress(snapshot))
        #expect(TodayWidgetState.at(date(11, 3), today: snapshot, forecast: nil, calendar: calendar) == .progress(snapshot), "still the 10th's Anki day")
        #expect(TodayWidgetState.at(date(11, 5), today: snapshot, forecast: nil, calendar: calendar)
            == .newDay(estimatedReviews: nil, estimatedNew: nil))
    }

    @Test func aNewDayIsEstimatedFromTheForecast() {
        let forecast = WidgetSnapshot(
            deckId: 0,
            deckName: "All Decks",
            newCount: 20,
            learnCount: 5,
            reviewCount: 120,
            reviewedToday: 180,
            streak: 3,
            lastSevenDays: Array(repeating: 0, count: 7),
            snapshotDate: date(10, 12),
            forecast: .init(
                rolloverHour: 4,
                dayZero: date(10, 4),
                days: [
                    .init(newCount: 20, learnCount: 5, reviewCount: 120),
                    .init(newCount: 20, learnCount: 0, reviewCount: 310),
                ]
            )
        )
        #expect(TodayWidgetState.at(date(11, 9), today: today(), forecast: forecast, calendar: calendar)
            == .newDay(estimatedReviews: 310, estimatedNew: 20))
    }

    @Test func aNewDayBringsAsManyNewCardsAsToday() {
        #expect(TodayWidgetState.at(date(11, 9), today: today(newLeft: 0), forecast: forecast(newCount: 0), calendar: calendar)
            == .newDay(estimatedReviews: 310, estimatedNew: 20), "today's new cards are done, but the daily limit brings 20 more")
    }

    @Test func nothingSavedYetIsUnknown() {
        #expect(TodayWidgetState.at(date(10, 12), today: nil, forecast: nil, calendar: calendar) == .unknown)
    }

    @Test func theWidgetRedrawsAtTheNextRollover() {
        #expect(TodayWidgetState.nextBoundary(after: date(10, 12), rolloverHour: 4, calendar: calendar) == date(11, 4))
        #expect(TodayWidgetState.nextBoundary(after: date(11, 2), rolloverHour: 4, calendar: calendar) == date(11, 4))
    }

    // MARK: - The number on the app icon

    /// All Decks, written at noon on the 10th: 310 reviews due on the 11th
    /// and 330 on the 12th if nothing is studied, and no further forecast.
    private func forecast(newCount: Int = 20) -> WidgetSnapshot {
        WidgetSnapshot(
            deckId: 0,
            deckName: "All Decks",
            newCount: newCount,
            learnCount: 5,
            reviewCount: 120,
            reviewedToday: 180,
            streak: 3,
            lastSevenDays: Array(repeating: 0, count: 7),
            snapshotDate: date(10, 12),
            forecast: .init(
                rolloverHour: 4,
                dayZero: date(10, 4),
                days: [
                    .init(newCount: newCount, learnCount: 5, reviewCount: 120),
                    .init(newCount: newCount, learnCount: 0, reviewCount: 310),
                    .init(newCount: newCount, learnCount: 0, reviewCount: 330),
                ]
            )
        )
    }

    @Test func theIconCountsWhatsLeftOfToday() {
        let state = TodayWidgetState.progress(today())
        #expect(AppIconBadge.cardsLeft.count(state) == 128)
        #expect(AppIconBadge.reviewsLeft.count(state) == 120)
        #expect(AppIconBadge.off.count(state) == 0)
        #expect(AppIconBadge.cardsLeft.count(.progress(today(reviewsLeft: 0, newLeft: 0))) == 0, "done for today: no number")
        #expect(AppIconBadge.cardsLeft.count(.unknown) == nil)
    }

    @Test func theIconTurnsGreenOnceWhatItCountsIsDone() {
        let noon = date(10, 12)
        #expect(!AppIconBadge.cardsLeft.isDone(today(), at: noon, calendar: calendar))
        #expect(!AppIconBadge.cardsLeft.isDone(today(reviewsLeft: 0), at: noon, calendar: calendar), "new cards still left")
        #expect(AppIconBadge.cardsLeft.isDone(today(reviewsLeft: 0, newLeft: 0), at: noon, calendar: calendar))
        #expect(AppIconBadge.reviewsLeft.isDone(today(reviewsLeft: 0), at: noon, calendar: calendar), "counting reviews only")
        #expect(!AppIconBadge.off.isDone(today(reviewsLeft: 0), at: noon, calendar: calendar), "no number: the whole minimum")
        #expect(AppIconBadge.off.isDone(today(reviewsLeft: 0, newLeft: 0), at: noon, calendar: calendar))
        #expect(!AppIconBadge.cardsLeft.isDone(today(reviewsLeft: 0, newLeft: 0), at: date(11, 5), calendar: calendar), "a new day has begun")
        #expect(!AppIconBadge.cardsLeft.isDone(nil, at: noon, calendar: calendar))
    }

    @Test func theIconMovesOnEachMorningWhileTheAppIsClosed() {
        let plan = AppIconBadge.cardsLeft.plan(now: date(10, 12), today: today(), forecast: forecast(), calendar: calendar)
        #expect(plan.now == 128)
        #expect(plan.changes == [
            AppIconBadgePlan.Change(date: date(11, 4), count: 330),
            AppIconBadgePlan.Change(date: date(12, 4), count: 350),
        ], "the forecast's reviews and today's 20 new cards; no change once the forecast runs out")
    }

    @Test func reviewsOnlyLeavesNewCardsOut() {
        let plan = AppIconBadge.reviewsLeft.plan(now: date(10, 12), today: today(), forecast: forecast(), calendar: calendar)
        #expect(plan.now == 120)
        #expect(plan.changes.map(\.count) == [310, 330])
    }

    @Test func offClearsTheIcon() {
        #expect(AppIconBadge.off.plan(now: date(10, 12), today: today(), forecast: forecast(), calendar: calendar)
            == AppIconBadgePlan(now: 0, changes: []))
    }

    @Test func withoutAForecastTheIconWaitsForTheApp() {
        let plan = AppIconBadge.cardsLeft.plan(now: date(10, 12), today: today(), forecast: nil, calendar: calendar)
        #expect(plan.now == 128)
        #expect(plan.changes.isEmpty)
        #expect(AppIconBadge.cardsLeft.plan(now: date(10, 12), today: nil, forecast: nil, calendar: calendar)
            == AppIconBadgePlan(now: nil, changes: []))
    }

    @Test func yesterdaysNumbersGiveWayToTheEstimate() {
        let plan = AppIconBadge.cardsLeft.plan(now: date(11, 9), today: today(), forecast: forecast(), calendar: calendar)
        #expect(plan.now == 330)
        #expect(plan.changes == [AppIconBadgePlan.Change(date: date(12, 4), count: 350)])
    }

    @Test func aSnapshotRoundTripsThroughTheStore() {
        let suite = "TodaySnapshotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(TodaySnapshotStore.read(from: defaults) == nil)
        TodaySnapshotStore.write(today(), to: defaults)
        #expect(TodaySnapshotStore.read(from: defaults) == today())
    }
}
