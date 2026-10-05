//
//  ScreenAwake.swift
//  ReviewFeature
//

#if canImport(UIKit)
import UIKit

/// Keeps the screen from locking while anything wants it on: hands-free
/// mode (Settings → Review → Hands-Free → Keep the screen on), or cards
/// being made ready for the AI voice.
@MainActor
enum ScreenAwake {
    enum Holder: Hashable {
        case handsFree
        case preparing
    }

    private static var holders: Set<Holder> = []

    static func keep(_ holder: Holder, _ on: Bool = true) {
        if on {
            holders.insert(holder)
        } else {
            holders.remove(holder)
        }
        UIApplication.shared.isIdleTimerDisabled = !holders.isEmpty
    }
}
#endif
