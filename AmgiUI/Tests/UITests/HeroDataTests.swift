//
//  HeroDataTests.swift
//  UITests
//

import Testing
@testable import UI

@Suite("HeroData")
struct HeroDataTests {

    private static let week = Array(repeating: 0, count: 14)

    @Test func theDayIsDoneOnceBothRoundsAreFinished() {
        let partWay = HeroData(reviewCount: 0, newCount: 8, reviewTotal: 300, newTotal: 20, streak: 1, last14Days: Self.week)
        #expect(!partWay.isDoneForToday, "new cards are still left")

        let done = HeroData(reviewCount: 0, newCount: 0, reviewTotal: 300, newTotal: 20, againCount: 14, streak: 1, last14Days: Self.week)
        #expect(done.isDoneForToday, "cards due again are extra, not part of the minimum")
    }

    @Test func aTotalIsNeverLessThanWhatsLeft() {
        let data = HeroData(reviewCount: 40, newCount: 5, reviewTotal: 10, streak: 0, last14Days: Self.week)
        #expect(data.reviewTotal == 40)
        #expect(data.newTotal == 5, "no total given: the day starts with what's left")
    }

    @Test func activityKeepsTheCounts() {
        let counts = HeroData(reviewCount: 120, newCount: 8, reviewTotal: 300, newTotal: 20, againCount: 3, streak: 0, last14Days: Self.week)
        let filled = counts.withActivity(streak: 36, last14Days: Array(repeating: 5, count: 14))
        #expect(filled.reviewTotal == 300 && filled.newTotal == 20 && filled.againCount == 3)
        #expect(filled.streak == 36)
    }
}
