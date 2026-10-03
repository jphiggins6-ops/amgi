//
//  ReviewGestures.swift
//  AppCore
//

public import AnkiKit
public import Foundation

/// Something done to the card or the phone while reviewing: a tap in one of
/// nine areas, a swipe, or a shake. What each one does is the user's choice
/// (Settings → Review Behavior → Taps, Swipes & Shake).
public enum ReviewGesture: String, CaseIterable, Identifiable, Sendable {
    case tapTopLeft, tapTopCenter, tapTopRight
    case tapMiddleLeft, tapCenter, tapMiddleRight
    case tapBottomLeft, tapBottomCenter, tapBottomRight
    case swipeLeft, swipeRight, swipeUp, swipeDown
    case shake

    public var id: String { rawValue }

    /// The nine tap areas, row by row from the top left.
    public static let taps: [ReviewGesture] = [
        .tapTopLeft, .tapTopCenter, .tapTopRight,
        .tapMiddleLeft, .tapCenter, .tapMiddleRight,
        .tapBottomLeft, .tapBottomCenter, .tapBottomRight,
    ]

    public static let swipes: [ReviewGesture] = [.swipeLeft, .swipeRight, .swipeUp, .swipeDown]

    /// The tap area holding a point given as fractions (0...1) of the card
    /// area's width and height. Out-of-range values clamp to the edge areas.
    public static func tap(x: Double, y: Double) -> ReviewGesture {
        func third(_ value: Double) -> Int {
            guard value.isFinite else { return 1 }
            // Clamped before the conversion, which traps outside Int's range.
            return Int(min(max(value, 0), 0.999) * 3)
        }
        return taps[third(y) * 3 + third(x)]
    }

    public var title: String {
        switch self {
        case .tapTopLeft: "Top left"
        case .tapTopCenter: "Top middle"
        case .tapTopRight: "Top right"
        case .tapMiddleLeft: "Middle left"
        case .tapCenter: "Center"
        case .tapMiddleRight: "Middle right"
        case .tapBottomLeft: "Bottom left"
        case .tapBottomCenter: "Bottom middle"
        case .tapBottomRight: "Bottom right"
        case .swipeLeft: "Swipe left"
        case .swipeRight: "Swipe right"
        case .swipeUp: "Swipe up"
        case .swipeDown: "Swipe down"
        case .shake: "Shake"
        }
    }

    /// Enough to review without the buttons, but nothing on the edges or
    /// corners, where a thumb resting on the screen is most likely to land,
    /// and nothing on a shake, which a bus ride can set off.
    public var defaultAction: ReviewGestureAction {
        switch self {
        case .tapCenter: .good
        case .tapMiddleLeft: .again
        case .swipeLeft: .again
        case .swipeRight: .good
        default: .nothing
        }
    }

    public var storageKey: String { "review_pref_gesture_\(rawValue)" }
}

/// What a gesture does. On the question side every rating shows the
/// answer instead, so a card can never be rated unseen.
public enum ReviewGestureAction: String, CaseIterable, Identifiable, Sendable {
    case nothing
    case showAnswer
    case again, hard, good, easy
    case undo
    case replayAudio
    case flagRed, flagOrange, flagGreen, flagBlue
    case editNote
    case visualMnemonic
    case explain
    case handsFree

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .nothing: "Nothing"
        case .showAnswer: "Show answer"
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        case .undo: "Undo"
        case .replayAudio: "Replay audio"
        case .flagRed: "Red flag"
        case .flagOrange: "Orange flag"
        case .flagGreen: "Green flag"
        case .flagBlue: "Blue flag"
        case .editNote: "Edit note"
        case .visualMnemonic: "Visual mnemonic"
        case .explain: "Explain (AI)"
        case .handsFree: "Hands-free on/off"
        }
    }

    public var rating: Rating? {
        switch self {
        case .again: .again
        case .hard: .hard
        case .good: .good
        case .easy: .easy
        default: nil
        }
    }

    /// Anki's flag number. Applying the flag a card already has clears it.
    public var flag: UInt32? {
        switch self {
        case .flagRed: 1
        case .flagOrange: 2
        case .flagGreen: 3
        case .flagBlue: 4
        default: nil
        }
    }
}

extension ReviewPreferences {
    public static func gestureAction(
        for gesture: ReviewGesture,
        in defaults: UserDefaults = .standard
    ) -> ReviewGestureAction {
        defaults.string(forKey: gesture.storageKey)
            .flatMap(ReviewGestureAction.init(rawValue:))
            ?? gesture.defaultAction
    }

    public static func setGestureAction(
        _ action: ReviewGestureAction,
        for gesture: ReviewGesture,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(action.rawValue, forKey: gesture.storageKey)
    }
}
