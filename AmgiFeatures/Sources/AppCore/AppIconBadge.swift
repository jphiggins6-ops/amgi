//
//  AppIconBadge.swift
//  AppCore
//

public import Foundation

/// What the number on Amgi's home-screen icon counts: what's left of
/// today's minimum, as on the Today widget, or nothing. Chosen in
/// Settings → Review.
public enum AppIconBadge: String, CaseIterable, Identifiable, Sendable {
    /// Reviews and new cards left today: both of the Library's study
    /// buttons.
    case cardsLeft
    /// Reviews left today, new cards aside.
    case reviewsLeft
    case off

    /// How many mornings ahead the number is set, for while the app stays
    /// closed: as far as the forecast reaches.
    public static let days = 7

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cardsLeft: "Reviews + New"
        case .reviewsLeft: "Reviews Only"
        case .off: "Off"
        }
    }

    /// The number for what the Today widget shows, or nil when that isn't
    /// known.
    public func count(_ state: TodayWidgetState) -> Int? {
        switch (self, state) {
        case (.off, _):
            return 0
        case (.cardsLeft, .progress(let today)):
            return today.cardsLeft
        case (.reviewsLeft, .progress(let today)):
            return today.reviewsLeft
        case (.cardsLeft, .newDay(let reviews?, let new)):
            return reviews + (new ?? 0)
        case (.reviewsLeft, .newDay(let reviews?, _)):
            return reviews
        case (_, .newDay), (_, .unknown):
            return nil
        }
    }

    /// The number to show now, and the number each of the next `days` Anki
    /// days begins with if the app isn't opened before then.
    public func plan(
        now: Date,
        today: TodaySnapshot?,
        forecast: WidgetSnapshot?,
        calendar: Calendar = .current
    ) -> AppIconBadgePlan {
        if self == .off { return AppIconBadgePlan(now: 0, changes: []) }
        guard let today else { return AppIconBadgePlan(now: nil, changes: []) }
        let current = self.count(.at(now, today: today, forecast: forecast, calendar: calendar))
        var changes: [AppIconBadgePlan.Change] = []
        var shown = current
        var boundary = now
        for _ in 0..<Self.days {
            boundary = TodayWidgetState.nextBoundary(
                after: boundary, rolloverHour: today.rolloverHour, calendar: calendar
            )
            guard let number = self.count(.at(boundary, today: today, forecast: forecast, calendar: calendar)),
                  number != shown
            else { continue }
            changes.append(AppIconBadgePlan.Change(date: boundary, count: number))
            shown = number
        }
        return AppIconBadgePlan(now: current, changes: changes)
    }
}

/// The numbers for the app icon: one for now, and one for each coming
/// morning that would change it.
public struct AppIconBadgePlan: Equatable, Sendable {
    public struct Change: Equatable, Sendable {
        /// When an Anki day begins.
        public var date: Date
        public var count: Int

        public init(date: Date, count: Int) {
            self.date = date
            self.count = count
        }
    }

    /// The number to show now; nil leaves the icon as it is.
    public var now: Int?
    /// In order, and only where the number differs from the day before.
    public var changes: [Change]

    public init(now: Int?, changes: [Change]) {
        self.now = now
        self.changes = changes
    }
}
