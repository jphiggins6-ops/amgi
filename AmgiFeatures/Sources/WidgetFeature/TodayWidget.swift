//
//  TodayWidget.swift
//  WidgetFeature
//

import WidgetKit
public import SwiftUI
import Foundation
import Theme
import AppCore

/// Today's minimum at a glance, on the home screen and the lock screen:
/// "120 of 300 left" for Reviews and New, turning green with a seal once
/// both are done. Reads what the Library last saved (`TodaySnapshot`); after
/// Anki's day rolls over it says so, with an estimate of the new day's cards.
public struct AmgiTodayWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: TodaySnapshot.widgetKind, provider: TodayTimelineProvider()) { entry in
            TodayWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Today's reviews and new cards left, and when you're done for the day.")
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        #if os(macOS)
        return [.systemSmall, .systemMedium]
        #else
        return [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #endif
    }
}

// MARK: - Timeline

struct TodayEntry: TimelineEntry {
    var date: Date
    var state: TodayWidgetState
}

struct TodayTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), state: .progress(.placeholder))
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(Self.entry(at: Date(), today: TodaySnapshotStore.read()))
        }
    }

    /// Now, and again at the next Anki day boundary, when today's numbers
    /// stop applying. WidgetKit asks again after that.
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        let today = TodaySnapshotStore.read()
        let boundary = TodayWidgetState.nextBoundary(after: now, rolloverHour: today?.rolloverHour ?? 4)
        let entries = [Self.entry(at: now, today: today), Self.entry(at: boundary, today: today)]
        completion(Timeline(entries: entries, policy: .after(boundary)))
    }

    static func entry(at date: Date, today: TodaySnapshot?) -> TodayEntry {
        TodayEntry(
            date: date,
            state: .at(date, today: today, forecast: WidgetSnapshotStore.read(deckId: 0))
        )
    }
}

// MARK: - Views

struct TodayWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: TodayEntry

    var body: some View {
        let palette = ThemeManager.shared.palette(for: colorScheme)
        content
            .environment(\.palette, palette)
            .containerBackground(for: .widget) {
                background(palette)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        #if !os(macOS)
        case .accessoryCircular:
            TodayCircularView(state: entry.state)
        case .accessoryRectangular:
            TodayRectangularView(state: entry.state)
        case .accessoryInline:
            TodayInlineView(state: entry.state)
        #endif
        case .systemMedium:
            TodayHomeView(state: entry.state, wide: true)
        default:
            TodayHomeView(state: entry.state, wide: false)
        }
    }

    @ViewBuilder
    private func background(_ palette: Palette) -> some View {
        if isAccessory {
            Color.clear
        } else if case .progress(let today) = entry.state, today.isDone {
            TodayDoneGradient()
        } else {
            palette.surface
        }
    }

    private var isAccessory: Bool {
        #if os(macOS)
        return false
        #else
        return family == .accessoryCircular || family == .accessoryRectangular || family == .accessoryInline
        #endif
    }
}

/// The Library hero's "done for today" green.
struct TodayDoneGradient: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.20, green: 0.70, blue: 0.40), Color(red: 0.05, green: 0.55, blue: 0.55)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Small and medium home-screen widgets.
struct TodayHomeView: View {
    @Environment(\.palette) private var palette
    let state: TodayWidgetState
    let wide: Bool

    var body: some View {
        Group {
            switch state {
            case .progress(let today) where today.isDone:
                done(today)
            case .progress(let today):
                progress(today)
            case .newDay(let reviews, let new):
                message(
                    title: "New day",
                    detail: TodayWidgetText.estimate(reviews: reviews, new: new),
                    hint: "Open Amgi to start"
                )
            case .unknown:
                message(title: "Today", detail: nil, hint: "Open Amgi to see today's cards")
            }
        }
        .padding(AmgiSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func progress(_ today: TodaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
            Text("TODAY")
                .amgiFont(.captionBold)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: AmgiSpacing.xs) {
                Text(verbatim: "\(today.cardsLeft)")
                    .amgiFont(size: wide ? 44 : 40, weight: .semibold, tracking: -1, relativeTo: .largeTitle)
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("left")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer(minLength: 0)
            TodayPartRow(title: "Reviews", left: today.reviewsLeft, total: today.reviewsTotal)
            TodayPartRow(title: "New", left: today.newLeft, total: today.newTotal)
        }
    }

    private func done(_ today: TodaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
            Image(systemName: "checkmark.seal.fill")
                .amgiFont(size: wide ? 34 : 30, weight: .bold, relativeTo: .largeTitle)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Text("Done for today")
                .amgiFont(size: wide ? 22 : 18, weight: .bold, relativeTo: .title3)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(verbatim: TodayWidgetText.doneDetail(today))
                .amgiFont(.caption)
                .opacity(0.85)
                .lineLimit(2)
        }
        .foregroundStyle(.white)
    }

    private func message(title: String, detail: String?, hint: String) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
            Text("TODAY")
                .amgiFont(.captionBold)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 0)
            Text(verbatim: title)
                .amgiFont(size: 20, weight: .bold, relativeTo: .title3)
                .foregroundStyle(palette.textPrimary)
            if let detail {
                Text(verbatim: detail)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(2)
            }
            Text(verbatim: hint)
                .amgiFont(.micro)
                .foregroundStyle(palette.textTertiary)
                .lineLimit(1)
        }
    }
}

/// "Reviews  120 of 300" with a thin bar, or a tick once it's done.
struct TodayPartRow: View {
    @Environment(\.palette) private var palette
    let title: String
    let left: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: AmgiSpacing.xs) {
                Text(verbatim: title)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 0)
                if left == 0 {
                    Image(systemName: "checkmark.circle.fill")
                        .amgiFont(.captionBold)
                        .foregroundStyle(palette.positive)
                        .accessibilityLabel("done")
                } else {
                    Text(verbatim: "\(left) of \(total)")
                        .amgiFont(.captionBold, .monospacedDigits)
                        .foregroundStyle(palette.textPrimary)
                }
            }
            ProgressView(value: Double(total - left), total: Double(max(total, 1)))
                .tint(left == 0 ? palette.positive : palette.accent)
        }
        .accessibilityElement(children: .combine)
    }
}

#if !os(macOS)

// MARK: - Lock screen

struct TodayCircularView: View {
    let state: TodayWidgetState

    var body: some View {
        switch state {
        case .progress(let today) where today.isDone:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
            }
            .accessibilityLabel("Done for today")
        case .progress(let today):
            Gauge(value: today.fractionDone) {
                Image(systemName: "rectangle.stack")
            } currentValueLabel: {
                Text(verbatim: "\(today.cardsLeft)")
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .accessibilityLabel("\(today.cardsLeft) cards left today")
        case .newDay, .unknown:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "rectangle.stack")
                    .font(.title3)
            }
            .accessibilityLabel("Amgi: open to see today's cards")
        }
    }
}

struct TodayRectangularView: View {
    let state: TodayWidgetState

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch state {
            case .progress(let today) where today.isDone:
                Label("Done for today", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                Text(verbatim: TodayWidgetText.doneDetail(today))
                    .font(.caption)
                    .lineLimit(2)
            case .progress(let today):
                Text("Amgi today")
                    .font(.headline)
                Text(verbatim: TodayWidgetText.part("Reviews", left: today.reviewsLeft, total: today.reviewsTotal))
                    .font(.caption)
                    .monospacedDigit()
                Text(verbatim: TodayWidgetText.part("New", left: today.newLeft, total: today.newTotal))
                    .font(.caption)
                    .monospacedDigit()
            case .newDay(let reviews, let new):
                Text("Amgi · new day")
                    .font(.headline)
                Text(verbatim: TodayWidgetText.estimate(reviews: reviews, new: new) ?? "Open Amgi to start")
                    .font(.caption)
                    .lineLimit(2)
            case .unknown:
                Text("Amgi")
                    .font(.headline)
                Text("Open Amgi to see today's cards")
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TodayInlineView: View {
    let state: TodayWidgetState

    var body: some View {
        switch state {
        case .progress(let today) where today.isDone:
            Label("Done for today", systemImage: "checkmark.seal.fill")
        case .progress(let today):
            Label(TodayWidgetText.inline(today), systemImage: "rectangle.stack")
        case .newDay, .unknown:
            Label("Amgi: new day", systemImage: "rectangle.stack")
        }
    }
}

#endif

// MARK: - Text

enum TodayWidgetText {
    static func part(_ title: String, left: Int, total: Int) -> String {
        left == 0 ? "\(title) ✓ done" : "\(title) \(left) of \(total)"
    }

    static func inline(_ today: TodaySnapshot) -> String {
        today.cardsLeft == 1 ? "1 card left today" : "\(today.cardsLeft) cards left today"
    }

    static func doneDetail(_ today: TodaySnapshot) -> String {
        if today.dueAgain > 0 { return "\(today.dueAgain) seen today are due again" }
        return "\(today.reviewsTotal) reviews · \(today.newTotal) new"
    }

    /// "About 310 reviews · 20 new", or nil with nothing to go on.
    static func estimate(reviews: Int?, new: Int?) -> String? {
        switch (reviews, new) {
        case let (reviews?, new?):
            return "About \(reviews) reviews · \(new) new"
        case let (reviews?, nil):
            return "About \(reviews) reviews"
        case let (nil, new?):
            return "About \(new) new"
        case (nil, nil):
            return nil
        }
    }
}

#if DEBUG
#Preview("Part way") {
    WidgetPreviewFrame(width: 170, height: 170) {
        TodayHomeView(state: .progress(.placeholder), wide: false)
    }
}

#Preview("Done") {
    var done = TodaySnapshot.placeholder
    done.reviewsLeft = 0
    done.newLeft = 0
    done.dueAgain = 14
    return WidgetPreviewFrame(width: 170, height: 170) {
        TodayHomeView(state: .progress(done), wide: false)
            .background(TodayDoneGradient())
    }
}
#endif
