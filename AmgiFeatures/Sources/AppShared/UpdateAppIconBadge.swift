//
//  UpdateAppIconBadge.swift
//  AppShared
//

public import AppCore
public import Foundation
#if os(iOS)
import UserNotifications
#endif

/// Puts what's left of today's minimum on Amgi's home-screen icon, as
/// chosen in Settings → Review, and lines up the number each of the next
/// few days begins with, so the icon moves on at the rollover while the
/// app is closed.
///
/// Those morning numbers are local notifications that carry nothing but a
/// badge: nothing appears on screen, only the icon changes. A badge needs
/// the notifications permission, which iOS asks for the first time there's
/// a number to show; only badges are asked for.
@MainActor
public func updateAppIconBadge(
    _ today: TodaySnapshot? = TodaySnapshotStore.read(),
    style: AppIconBadge = ReviewPreferences.appIconBadge,
    now: Date = Date()
) async {
    // Not from tests or previews: there's no icon to badge, and the
    // notification center can't be reached from them.
    let environment = ProcessInfo.processInfo.environment
    if environment["XCTestConfigurationFilePath"] != nil || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
        return
    }
    #if os(iOS)
    await IconBadge.update(today, style: style, now: now)
    #endif
}

#if os(iOS)
@MainActor
private enum IconBadge {
    /// Counts updates, so one still waiting on the permission prompt can't
    /// overwrite a newer one.
    static var latest = 0

    static let identifiers = (1...AppIconBadge.days).map { "app-icon-badge-day-\($0)" }

    static func update(_ today: TodaySnapshot?, style: AppIconBadge, now: Date) async {
        latest += 1
        let thisUpdate = latest
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        guard style != .off else {
            UNUserNotificationCenter.current().setBadgeCount(0, withCompletionHandler: nil)
            return
        }
        guard await isAllowed(), thisUpdate == latest else { return }
        let plan = style.plan(now: now, today: today, forecast: WidgetSnapshotStore.read(deckId: 0))
        if let count = plan.now {
            UNUserNotificationCenter.current().setBadgeCount(count, withCompletionHandler: nil)
        }
        for (change, identifier) in zip(plan.changes, identifiers) {
            UNUserNotificationCenter.current().add(request(change, identifier: identifier), withCompletionHandler: nil)
        }
    }

    /// Asks the first time; after that, answers straight away.
    private static func isAllowed() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.badge],
                completionHandler: resuming(continuation)
            )
        }
    }

    /// A notification that only sets the badge, when `change` is due.
    private static func request(_ change: AppIconBadgePlan.Change, identifier: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.badge = NSNumber(value: change.count)
        let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: change.date)
        return UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
        )
    }

    /// Built outside the main actor: the notification center answers on a
    /// queue of its own, and a main-actor closure run there would trap.
    nonisolated private static func resuming(
        _ continuation: CheckedContinuation<Bool, Never>
    ) -> @Sendable (Bool, (any Error)?) -> Void {
        { granted, _ in continuation.resume(returning: granted) }
    }
}
#endif
