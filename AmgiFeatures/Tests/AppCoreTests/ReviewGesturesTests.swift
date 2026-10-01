//
//  ReviewGesturesTests.swift
//  AppCoreTests
//

import Foundation
import Testing
import AnkiKit
@testable import AppCore

@Suite struct ReviewGesturesTests {

    @Test func aTapLandsInTheThirdItFallsIn() {
        let cases: [(x: Double, y: Double, expected: ReviewGesture)] = [
            (0.10, 0.10, .tapTopLeft),
            (0.50, 0.10, .tapTopCenter),
            (0.90, 0.10, .tapTopRight),
            (0.10, 0.50, .tapMiddleLeft),
            (0.50, 0.50, .tapCenter),
            (0.90, 0.50, .tapMiddleRight),
            (0.10, 0.90, .tapBottomLeft),
            (0.50, 0.90, .tapBottomCenter),
            (0.90, 0.90, .tapBottomRight),
        ]
        for tap in cases {
            #expect(ReviewGesture.tap(x: tap.x, y: tap.y) == tap.expected, "tap at (\(tap.x), \(tap.y))")
        }
    }

    @Test func tapsOnOrPastTheEdgeStayInTheEdgeAreas() {
        #expect(ReviewGesture.tap(x: 1.0, y: 1.0) == .tapBottomRight)
        #expect(ReviewGesture.tap(x: -0.2, y: 1.4) == .tapBottomLeft)
        #expect(ReviewGesture.tap(x: .nan, y: .infinity) == .tapCenter)
    }

    @Test func everyTapAreaAppearsOnceInGridOrder() {
        #expect(ReviewGesture.taps.count == 9)
        #expect(Set(ReviewGesture.taps).count == 9)
        #expect(Set(ReviewGesture.taps + ReviewGesture.swipes + [.shake]) == Set(ReviewGesture.allCases))
    }

    @Test func onlyTheFourAnswerActionsRate() {
        let rating = ReviewGestureAction.allCases.compactMap(\.rating)
        #expect(rating == [.again, .hard, .good, .easy])
    }

    @Test func aChoiceIsRememberedAndAnUnknownValueFallsBackToTheDefault() {
        let suite = "ReviewGesturesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ReviewPreferences.gestureAction(for: .tapCenter, in: defaults) == .good)
        #expect(ReviewPreferences.gestureAction(for: .tapTopLeft, in: defaults) == .nothing)
        #expect(ReviewPreferences.gestureAction(for: .shake, in: defaults) == .nothing, "a shake does nothing until it's set")

        ReviewPreferences.setGestureAction(.undo, for: .shake, in: defaults)
        #expect(ReviewPreferences.gestureAction(for: .shake, in: defaults) == .undo)

        ReviewPreferences.setGestureAction(.undo, for: .tapTopLeft, in: defaults)
        #expect(ReviewPreferences.gestureAction(for: .tapTopLeft, in: defaults) == .undo)

        // Written by a newer build with an action this one doesn't know.
        defaults.set("teleport", forKey: ReviewGesture.swipeUp.storageKey)
        #expect(ReviewPreferences.gestureAction(for: .swipeUp, in: defaults) == .nothing)
    }
}
