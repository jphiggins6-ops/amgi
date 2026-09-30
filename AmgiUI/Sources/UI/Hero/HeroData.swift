//
//  HeroData.swift
//  UI
//
//  Created by Vladimir Gusev on 15.05.2026.
//

import Foundation

/// Hero-card payload. Anki-agnostic — populated by the container by
/// aggregating from domain models.
public struct HeroData: Equatable, Hashable, Sendable {
    /// Cards the Reviews button would study now.
    public let reviewCount: Int
    /// New cards the New button would introduce today.
    public let newCount: Int
    public let streak: Int
    public let last14Days: [Int]    // oldest → newest, length 14

    public init(reviewCount: Int, newCount: Int, streak: Int, last14Days: [Int]) {
        self.reviewCount = reviewCount
        self.newCount = newCount
        self.streak = streak
        self.last14Days = last14Days
    }

    public static let zero = HeroData(
        reviewCount: 0,
        newCount: 0,
        streak: 0,
        last14Days: Array(repeating: 0, count: 14)
    )
}
