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
    /// Long Answers cards past their grace (`LongAnswers`), not yet
    /// answered today: part of today's minimum. Nil in a snapshot saved
    /// before there was a Long Answers deck.
    public var longAnswersRequired: Int?

    public init(
        reviewsLeft: Int,
        reviewsTotal: Int,
        newLeft: Int,
        newTotal: Int,
        dueAgain: Int,
        dayStart: Date,
        rolloverHour: Int,
        longAnswersRequired: Int = 0
    ) {
        self.reviewsLeft = reviewsLeft
        self.reviewsTotal = max(reviewsTotal, reviewsLeft)
        self.newLeft = newLeft
        self.newTotal = max(newTotal, newLeft)
        self.dueAgain = dueAgain
        self.dayStart = dayStart
        self.rolloverHour = rolloverHour
        self.longAnswersRequired = longAnswersRequired
    }

    /// Every due card seen once, today's new cards learned, and no Long
    /// Answers card past its grace.
    public var isDone: Bool {
        reviewsLeft == 0 && newLeft == 0 && (longAnswersRequired ?? 0) == 0
    }

    /// What's left of today's minimum, Long Answers cards past their grace
    /// included.
    public var cardsLeft: Int { reviewsLeft + newLeft + (longAnswersRequired ?? 0) }

    /// How much of today's reviews and new cards is done, 0...1. A day with
    /// nothing to do is done.
    public var fractionDone: Double {
        let total = reviewsTotal + newTotal
        guard total > 0 else { return 1 }
        return Double(total - reviewsLeft - newLeft) / Double(total)
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
    /// reviews come from the All Decks forecast, which counts every deck
    /// and flag, so they're a guide rather than the Library's exact
    /// figure. The new cards are as many as today brought: the daily
    /// limits bring as many again, however many of today's are done.
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
            estimatedNew: today.newTotal
        )
    }

    /// The next Anki day boundary after `date`, when the widget must redraw.
    public static func nextBoundary(after date: Date, rolloverHour: Int, calendar: Calendar = .current) -> Date {
        let start = AnkiDay.start(of: date, rolloverHour: rolloverHour, calendar: calendar)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }
}

/// The day's studying done, for other apps of the same developer team to
/// read through the app group (`group.com.amgiapp`): the habit tracker
/// ticks its "Anki" habit with it. Written when today's minimum is done, as
/// the icon turns green (`updateAppIcon`), and never cleared: a reader
/// compares the day with its own today.
///
/// In the group's shared defaults (`UserDefaults(suiteName:
/// "group.com.amgiapp")`):
/// - `amgi.studyDoneDay`: the day finished, "yyyy-MM-dd", the date the Anki
///   day started on (Anki's day starts at 4 am unless set otherwise, so
///   cards finished at 1 am count for the day before).
/// - `amgi.studyDoneAt`: when, in seconds since 1970.
public enum StudyDoneSignal {
    public static let dayKey = "amgi.studyDoneDay"
    public static let atKey = "amgi.studyDoneAt"

    /// Marks the Anki day `today` describes as done.
    public static func record(_ today: TodaySnapshot, at date: Date = Date(), in defaults: UserDefaults = AppGroup.defaults) {
        let day = day(of: today.dayStart)
        guard defaults.string(forKey: dayKey) != day else { return }
        defaults.set(day, forKey: dayKey)
        defaults.set(date.timeIntervalSince1970, forKey: atKey)
    }

    /// "2026-10-13": the local date `date` falls on.
    public static func day(of date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// The Long Answers deck: cards that take a while to answer, written out
/// or drawn (the brachial plexus, the basal ganglia's circuits), studied
/// with the Library's own button for them when there's time.
///
/// Its cards stay out of the Reviews and New buttons, and a card due there
/// becomes part of today's minimum (the green icon, the habit tracker's
/// tick) only once it has waited `graceDays` past its due date: due on
/// Monday, it's optional Monday to Wednesday and required from Thursday.
/// A top-level deck, made the first time the Library opens.
public enum LongAnswers {
    public static let deckName = "Long Answers"
    /// Days past its due date a card can wait before it's required.
    public static let graceDays = 3

    /// The deck, in a search.
    public static let deckSearch = "\"deck:\(deckName)\""
    /// Leaves the deck out of a search.
    public static let excluded = "-\(deckSearch)"
    /// Its cards waiting past their grace, unflagged, not yet answered
    /// today.
    public static let requiredSearch = "\(deckSearch) is:due prop:due<=-\(graceDays) flag:0 -rated:1"

    /// Whether `name`, a deck's full name, is the Long Answers deck.
    public static func isDeck(named name: String) -> Bool {
        name.caseInsensitiveCompare(deckName) == .orderedSame
    }
}

/// The Peripheral Nerve Examination deck: studied with Reviews and New
/// buttons of its own in the Library, whenever there's time. Its cards stay
/// out of the main Reviews and New buttons and never count toward today's
/// minimum (the green icon, the widget, the habit tracker's tick). Found
/// wherever it sits in the deck tree.
public enum NerveExam {
    public static let deckName = "Peripheral Nerve Examination"

    /// The deck and its subdecks, at the top level or inside another deck.
    public static let deckSearch = "(\"deck:\(deckName)\" OR \"deck:*::\(deckName)\")"
    /// Leaves the deck out of a search.
    public static let excluded = "-\"deck:\(deckName)\" -\"deck:*::\(deckName)\""

    /// Whether `name`, a deck's own name (its last part), is this deck.
    public static func isDeck(named name: String) -> Bool {
        name.caseInsensitiveCompare(deckName) == .orderedSame
    }
}
