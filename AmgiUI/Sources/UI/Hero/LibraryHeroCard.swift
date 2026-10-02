//
//  LibraryHeroCard.swift
//  UI
//
//  Created by Vladimir Gusev on 14.05.2026.
//

public import SwiftUI
import Theme

/// Library hero card: today's two study buttons, Reviews and New, under the
/// streak pill and over the 14-day sparkline.
///
/// Each button shows what's left of today's fixed total ("120 of 300") and
/// turns into a tick once it's done. Once every due card has been seen,
/// Reviews offers another look at the ones due again, if any. When both are
/// done the whole card turns green and says so: today's minimum is met.
public struct LibraryHeroCard: View {
    let data: HeroData
    let onStartReviews: () -> Void
    let onStartNew: () -> Void
    /// True while the review-history fetch that feeds `streak` and
    /// `last14Days` is still in flight. The counts come from the deck tree
    /// and a search, and are real immediately, so the card renders at once
    /// and only the history-derived decorations are shown as placeholders —
    /// a confident "0 day streak" that flips to 36 a second later is a worse
    /// answer than an obvious placeholder.
    let activityPending: Bool

    @Environment(\.palette) private var palette

    public init(
        data: HeroData,
        activityPending: Bool = false,
        onStartReviews: @escaping () -> Void,
        onStartNew: @escaping () -> Void
    ) {
        self.data = data
        self.activityPending = activityPending
        self.onStartReviews = onStartReviews
        self.onStartNew = onStartNew
    }

    public var body: some View {
        AmgiCard(background: heroGradient, shadow: palette.shadows.md) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    header
                    Spacer(minLength: 12)
                    StreakBadge(days: data.streak)
                        .redacted(reason: activityPending ? .placeholder : [])
                }

                HStack(spacing: 12) {
                    HeroStudyButton(tile: reviewsTile, action: onStartReviews)
                    HeroStudyButton(tile: newTile, action: onStartNew)
                }

                SparklineBars(values: data.last14Days)
                    .frame(height: 28)
                    .redacted(reason: activityPending ? .placeholder : [])
            }
        }
        .animation(AmgiMotion.standard, value: data.isDoneForToday)
    }

    @ViewBuilder
    private var header: some View {
        if data.isDoneForToday {
            Label("DONE FOR TODAY", systemImage: "checkmark.seal.fill")
                .amgiFont(size: 13, weight: .bold, tracking: 0.4, relativeTo: .footnote)
                .foregroundStyle(.white)
                .accessibilityLabel("Done for today: every due card seen and today's new cards learned")
        } else {
            Text("TODAY")
                .amgiFont(size: 13, weight: .semibold, tracking: 0.4, relativeTo: .footnote)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    /// Reviews: today's first look at every due card, then, once that's
    /// done, another look at the cards due again.
    private var reviewsTile: HeroTile {
        if data.reviewCount > 0 {
            return HeroTile(
                title: "Reviews",
                systemImage: "arrow.clockwise",
                status: .toDo(left: data.reviewCount, total: data.reviewTotal)
            )
        }
        if data.againCount > 0 {
            return HeroTile(
                title: "Due again",
                systemImage: "arrow.uturn.backward",
                status: .again(data.againCount)
            )
        }
        return HeroTile(
            title: "Reviews",
            systemImage: "arrow.clockwise",
            status: .done(hadAny: data.reviewTotal > 0)
        )
    }

    private var newTile: HeroTile {
        let status: HeroTile.Status
        if data.newCount > 0 {
            status = .toDo(left: data.newCount, total: data.newTotal)
        } else {
            status = .done(hadAny: data.newTotal > 0)
        }
        return HeroTile(title: "New", systemImage: "sparkles", status: status)
    }

    /// Indigo while there's work left; green once today's minimum is done.
    private var heroGradient: AmgiCardBackground {
        if data.isDoneForToday {
            return .gradient(
                start: Color(red: 0.20, green: 0.70, blue: 0.40), // green
                end: Color(red: 0.05, green: 0.55, blue: 0.55),   // teal
                angle: .degrees(155)
            )
        }
        return .gradient(
            start: palette.accent,
            end: Color(red: 0.37, green: 0.36, blue: 0.91), // #5E5CE6 Apple indigo
            angle: .degrees(155)
        )
    }
}

// MARK: - Study button

/// What one of the hero's buttons shows.
private struct HeroTile {
    enum Status {
        /// Cards left of today's fixed total.
        case toDo(left: Int, total: Int)
        /// Today's round is done; these cards, seen today, are due again.
        case again(Int)
        /// Nothing left today. `hadAny` is false when there was nothing to
        /// do in the first place.
        case done(hadAny: Bool)
    }

    let title: String
    let systemImage: String
    let status: Status
}

/// One of the hero's two big buttons: what it studies, how many are left
/// of today's total, and a start cue. The whole tile is the button.
private struct HeroStudyButton: View {
    let tile: HeroTile
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Label(tile.title, systemImage: tile.systemImage)
                    .amgiFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                figure
                Label(cue, systemImage: cueImage)
                    .amgiFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.white.opacity(isDone ? 0.12 : 0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        // An explicit style, not the default: inside a List row the default
        // makes the whole row the hit area, so a tap would press both buttons.
        .buttonStyle(.pressScale)
        .disabled(isDone)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isDone ? "" : "Starts studying")
    }

    /// The big figure: cards left with today's total beside it, or a tick.
    @ViewBuilder
    private var figure: some View {
        switch tile.status {
        case .toDo(let left, let total):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                bigNumber(left)
                Text(verbatim: "of \(total)")
                    .amgiFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .fixedSize()
            }
        case .again(let count):
            bigNumber(count)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .amgiFont(size: 40, weight: .bold, relativeTo: .largeTitle)
                .foregroundStyle(.white)
                .frame(height: 52, alignment: .leading)
        }
    }

    private func bigNumber(_ value: Int) -> some View {
        Text(verbatim: "\(value)")
            .amgiFont(size: 44, weight: .bold, tracking: -1, relativeTo: .largeTitle)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(.white)
    }

    private var isDone: Bool {
        if case .done = tile.status { return true }
        return false
    }

    private var cue: String {
        switch tile.status {
        case .toDo(let left, let total): left < total ? "Continue" : "Start"
        case .again: "Review again"
        case .done(let hadAny): hadAny ? "Done" : "None today"
        }
    }

    private var cueImage: String {
        switch tile.status {
        case .toDo: "play.fill"
        case .again: "arrow.uturn.backward"
        case .done: "checkmark"
        }
    }

    private var accessibilityText: String {
        switch tile.status {
        case .toDo(let left, let total):
            "\(tile.title), \(left) of \(total) \(total == 1 ? "card" : "cards") left today"
        case .again(let count):
            "\(count) \(count == 1 ? "card" : "cards") seen today and due again"
        case .done(let hadAny):
            hadAny ? "\(tile.title), done for today" : "\(tile.title), none today"
        }
    }
}

// MARK: - Streak pill

private struct StreakBadge: View {
    let days: Int

    var body: some View {
        if days > 0 {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .amgiFont(size: 12, weight: .bold, relativeTo: .footnote)
                Text("\(days)")
                    .amgiFont(size: 14, weight: .semibold, relativeTo: .footnote)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(.white.opacity(0.22), in: Capsule())
        }
    }
}

// MARK: - 14-day sparkline

private struct SparklineBars: View {
    let values: [Int]

    var body: some View {
        let maxValue = max(values.max() ?? 0, 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    // A zero day is a faint baseline tick, not a short bar —
                    // the 4pt floor otherwise renders 0 and 1 identically, and
                    // an all-zero series as 14 stubs that read as real data.
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(.white.opacity(value == 0 ? 0.18 : 0.55))
                        .frame(height: value == 0
                               ? 2
                               : max(4, geo.size.height * CGFloat(value) / CGFloat(maxValue)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Populated") {
    LibraryHeroCard(
        data: HeroData(
            reviewCount: 680,
            newCount: 20,
            streak: 36,
            last14Days: [3, 5, 2, 7, 6, 9, 4, 8, 6, 5, 7, 3, 8, 5]
        ),
        onStartReviews: {},
        onStartNew: {}
    )
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .environment(\.palette, .vividLight)
}

#Preview("Part way through the day") {
    LibraryHeroCard(
        data: HeroData(
            reviewCount: 120,
            newCount: 8,
            reviewTotal: 300,
            newTotal: 20,
            streak: 36,
            last14Days: [3, 5, 2, 7, 6, 9, 4, 8, 6, 5, 7, 3, 8, 5]
        ),
        onStartReviews: {},
        onStartNew: {}
    )
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .environment(\.palette, .vividLight)
}

#Preview("Done for today, some due again") {
    LibraryHeroCard(
        data: HeroData(
            reviewCount: 0,
            newCount: 0,
            reviewTotal: 300,
            newTotal: 20,
            againCount: 14,
            streak: 37,
            last14Days: [3, 5, 2, 7, 6, 9, 4, 8, 6, 5, 7, 3, 8, 9]
        ),
        onStartReviews: {},
        onStartNew: {}
    )
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .environment(\.palette, .vividLight)
}

#Preview("Nothing left — buttons disabled") {
    LibraryHeroCard(
        data: HeroData(
            reviewCount: 0,
            newCount: 0,
            streak: 12,
            last14Days: [3, 5, 0, 0, 6, 9, 4, 8, 6, 0, 7, 3, 8, 0]
        ),
        onStartReviews: {},
        onStartNew: {}
    )
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .environment(\.palette, .vividLight)
}

#Preview("Streak zero — badge hidden") {
    LibraryHeroCard(
        data: HeroData(
            reviewCount: 42,
            newCount: 0,
            streak: 0,
            last14Days: Array(repeating: 0, count: 14)
        ),
        onStartReviews: {},
        onStartNew: {}
    )
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .environment(\.palette, .vividLight)
}
#endif
