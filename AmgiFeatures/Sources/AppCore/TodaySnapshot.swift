//
//  TodaySnapshot.swift
//  AppCore
//

public import Foundation

/// Where today's minimum stands, for the Today widget and the lock screen:
/// the Library's Reviews and New buttons as they last were. Written by the
/// app whenever the Library loads, read by the widget extension through the
/// app group.
public struct TodaySnapshot: Codable, Sendable, Equatable {
    /// The widget's kind, shared so the app can ask WidgetKit to reload it.
    public static let widgetKind = "AmgiToday"

    public var reviewsLeft: Int
    public var reviewsTotal: Int
    public var newLeft: Int
    public var newTotal: Int
    /// Cards seen today that are due again.
    public var dueAgain: Int
    /// Start of the Anki day these numbers belong to.
    public var dayStart: Date
    /// Anki's day-boundary hour (default 4 am).
    public var rolloverHour: Int

    public init(
        reviewsLeft: Int,
        reviewsTotal: Int,
        newLeft: Int,
        newTotal: Int,
        dueAgain: Int,
        dayStart: Date,
        rolloverHour: Int
    ) {
        self.reviewsLeft = reviewsLeft
        self.reviewsTotal = max(reviewsTotal, reviewsLeft)
        self.newLeft = newLeft
        self.newTotal = max(newTotal, newLeft)
        self.dueAgain = dueAgain
        self.dayStart = dayStart
        self.rolloverHour = rolloverHour
    }

    /// Every due card seen once and today's new cards learned.
    public var isDone: Bool {
        reviewsLeft == 0 && newLeft == 0
    }

    public var cardsLeft: Int { reviewsLeft + newLeft }

    /// How much of today's minimum is done, 0...1. A day with nothing to
    /// do is done.
    public var fractionDone: Double {
        let total = reviewsTotal + newTotal
        guard total > 0 else { return 1 }
        return Double(total - cardsLeft) / Double(total)
    }

    /// When these numbers stop applying: the next Anki day boundary.
    public func dayEnd(calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
    }

    /// Whether the numbers still describe the Anki day `date` falls in.
    public func isCurrent(at date: Date, calendar: Calendar = .current) -> Bool {
        date >= dayStart && date < dayEnd(calendar: calendar)
    }

    public static let placeholder = TodaySnapshot(
        reviewsLeft: 120,
        reviewsTotal: 300,
        newLeft: 8,
        newTotal: 20,
        dueAgain: 0,
        dayStart: AnkiDay.start(of: Date(), rolloverHour: 4),
        rolloverHour: 4
    )
}

/// The Today widget's copy of `TodaySnapshot`, in the app group's defaults.
public enum TodaySnapshotStore {
    static let key = "widget_today_snapshot"

    public static func write(_ snapshot: TodaySnapshot, to defaults: UserDefaults = AppGroup.defaults) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    public static func read(from defaults: UserDefaults = AppGroup.defaults) -> TodaySnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TodaySnapshot.self, from: data)
    }
}

/// What the Today widget shows at a given moment.
public enum TodayWidgetState: Equatable, Sendable {
    /// Today's numbers, as the app last saw them.
    case progress(TodaySnapshot)
    /// A new Anki day has begun since the app last saved them. The
    /// estimate comes from the All Decks forecast, which counts every deck
    /// and flag, so it's a guide rather than the Library's exact figure.
    case newDay(estimatedReviews: Int?, estimatedNew: Int?)
    /// The app hasn't saved anything yet.
    case unknown

    public static func at(
        _ date: Date,
        today: TodaySnapshot?,
        forecast: WidgetSnapshot?,
        calendar: Calendar = .current
    ) -> TodayWidgetState {
        guard let today else { return .unknown }
        if today.isCurrent(at: date, calendar: calendar) { return .progress(today) }
        guard let forecast, forecast.forecast != nil,
              let projected = forecast.projectedEntries(now: date, calendar: calendar).first?.snapshot
        else { return .newDay(estimatedReviews: nil, estimatedNew: nil) }
        return .newDay(
            estimatedReviews: projected.reviewCount + projected.learnCount,
            estimatedNew: projected.newCount
        )
    }

    /// The next Anki day boundary after `date`, when the widget must redraw.
    public static func nextBoundary(after date: Date, rolloverHour: Int, calendar: Calendar = .current) -> Date {
        let start = AnkiDay.start(of: date, rolloverHour: rolloverHour, calendar: calendar)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }
}
