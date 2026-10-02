//
//  HeroData.swift
//  UI
//
//  Created by Vladimir Gusev on 15.05.2026.
//

import Foundation

/// Hero-card payload. Anki-agnostic — populated by the container by
/// aggregating from domain models.
///
/// Today's minimum is every due card seen once and today's new cards
/// learned. Each button's count is what's left of that and stays put as
/// cards come due again: `reviewTotal` and `newTotal` are fixed for the day.
public struct HeroData: Equatable, Hashable, Sendable {
    /// Due cards not yet seen today: what the Reviews button shows next.
    public let reviewCount: Int
    /// Today's due cards in all: those already seen plus `reviewCount`.
    public let reviewTotal: Int
    /// New cards left today.
    public let newCount: Int
    /// Today's new cards in all: those learned plus `newCount`.
    public let newTotal: Int
    /// Cards seen today that are due again: what Reviews offers once every
    /// due card has been seen.
    public let againCount: Int
    public let streak: Int
    public let last14Days: [Int]    // oldest → newest, length 14

    /// Totals default to what's left, as at the start of a day.
    public init(
        reviewCount: Int,
        newCount: Int,
        reviewTotal: Int? = nil,
        newTotal: Int? = nil,
        againCount: Int = 0,
        streak: Int,
        last14Days: [Int]
    ) {
        self.reviewCount = reviewCount
        self.reviewTotal = max(reviewTotal ?? reviewCount, reviewCount)
        self.newCount = newCount
        self.newTotal = max(newTotal ?? newCount, newCount)
        self.againCount = againCount
        self.streak = streak
        self.last14Days = last14Days
    }

    /// Today's minimum is done: every due card seen once, today's new
    /// cards learned.
    public var isDoneForToday: Bool {
        reviewCount == 0 && newCount == 0
    }

    /// The same counts with the review-history decorations filled in.
    public func withActivity(streak: Int, last14Days: [Int]) -> HeroData {
        HeroData(
            reviewCount: reviewCount,
            newCount: newCount,
            reviewTotal: reviewTotal,
            newTotal: newTotal,
            againCount: againCount,
            streak: streak,
            last14Days: last14Days
        )
    }

    public static let zero = HeroData(
        reviewCount: 0,
        newCount: 0,
        streak: 0,
        last14Days: Array(repeating: 0, count: 14)
    )
}
