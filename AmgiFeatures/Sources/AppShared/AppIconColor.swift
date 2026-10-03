//
//  AppIconColor.swift
//  AppShared
//

import Foundation
#if canImport(UIKit)
import OSLog
import AppCore
import UIKit
#endif

/// Turns Amgi's icon green once today is done, and back to the usual blue
/// stars when a new day starts. `updateAppIcon` decides which.
///
/// iOS only lets an app change its icon while it's open, and says so in an
/// alert each time ("You have changed the icon for “Amgi”"). So a change
/// waits until the app is in front with nothing else open, where the alert
/// can't get in the way of a sheet that's opening, and it can be held back
/// while something is about to open by itself, like the end-of-day summary.
@MainActor
public enum AppIconColor {
    /// The green icon's set in Assets.xcassets, named in project.yml's
    /// ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES.
    static let doneIconName = "AppIconDone"

    /// Whether the icon should be green, as last asked.
    private static var wantsDone: Bool?
    private static var heldUntil: Date?
    private static var isChanging = false
    private static var attempt: Task<Void, Never>?

    /// Green when `done`, the usual icon otherwise, as soon as the app is
    /// in front with nothing else open.
    public static func show(done: Bool) {
        wantsDone = done
        applySoon()
    }

    /// Holds changes back until `release()`, for two minutes at most.
    public static func hold() {
        heldUntil = Date().addingTimeInterval(120)
    }

    public static func release() {
        heldUntil = nil
        applySoon()
    }

    /// Unit tests and previews have no icon to change.
    static var isTestOrPreview: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    private static func applySoon() {
        guard !isTestOrPreview else { return }
        attempt?.cancel()
        attempt = Task {
            // A few tries, a second apart: a sheet may be closing, or the
            // app may only just have opened.
            for _ in 0..<10 {
                if Task.isCancelled { return }
                if await applied() { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Whether the icon is as wanted, or can't be changed at all.
    private static func applied() async -> Bool {
        #if canImport(UIKit)
        guard let done = wantsDone else { return true }
        let app = UIApplication.shared
        // False until the project lists the green icon (see `doneIconName`).
        guard app.supportsAlternateIcons else { return true }
        let wanted = done ? doneIconName : nil
        if app.alternateIconName == wanted { return true }
        if let until = heldUntil, until > Date() { return false }
        guard !isChanging, app.applicationState == .active, !somethingIsOpen else { return false }
        isChanging = true
        defer { isChanging = false }
        do {
            try await app.setAlternateIconName(wanted)
            return true
        } catch {
            Log.widget.error("Changing the app icon failed: \(error)")
            return false
        }
        #else
        return true
        #endif
    }

    #if canImport(UIKit)
    /// A sheet, alert or full-screen cover over the app's main screen.
    private static var somethingIsOpen: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.isKeyWindow && $0.rootViewController?.presentedViewController != nil }
    }
    #endif
}
