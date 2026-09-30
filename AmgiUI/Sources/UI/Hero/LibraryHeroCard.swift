//
//  LibraryHeroCard.swift
//  UI
//
//  Created by Vladimir Gusev on 14.05.2026.
//

public import SwiftUI
import Theme

/// Library hero card: today's two study buttons, Reviews and New, each
/// with its own count, under the streak pill and over the 14-day sparkline.
///
/// A button whose count is 0 is disabled; the rest still renders so the
/// user sees their streak and sparkline.
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
                    Text("TODAY")
                        .amgiFont(size: 13, weight: .semibold, tracking: 0.4, relativeTo: .footnote)
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer(minLength: 12)
                    StreakBadge(days: data.streak)
                        .redacted(reason: activityPending ? .placeholder : [])
                }

                HStack(spacing: 12) {
                    HeroStudyButton(
                        title: "Reviews",
                        systemImage: "arrow.clockwise",
                        count: data.reviewCount,
                        action: onStartReviews
                    )
                    HeroStudyButton(
                        title: "New",
                        systemImage: "sparkles",
                        count: data.newCount,
                        action: onStartNew
                    )
                }

                SparklineBars(values: data.last14Days)
                    .frame(height: 28)
                    .redacted(reason: activityPending ? .placeholder : [])
            }
        }
    }

    private var heroGradient: AmgiCardBackground {
        .gradient(
            start: palette.accent,
            end: Color(red: 0.37, green: 0.36, blue: 0.91), // #5E5CE6 Apple indigo
            angle: .degrees(155)
        )
    }
}

// MARK: - Study button

/// One of the hero's two big buttons: what it studies, how many, and a
/// start cue. The whole tile is the button.
private struct HeroStudyButton: View {
    let title: String
    let systemImage: String
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: systemImage)
                    .amgiFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(count)")
                    .amgiFont(size: 44, weight: .bold, tracking: -1, relativeTo: .largeTitle)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(.white)
                Label("Start", systemImage: "play.fill")
                    .amgiFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        // An explicit style, not the default: inside a List row the default
        // makes the whole row the hit area, so a tap would press both buttons.
        .buttonStyle(.pressScale)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.55 : 1)
        .accessibilityLabel("\(title), \(count) \(count == 1 ? "card" : "cards")")
        .accessibilityHint(count == 0 ? "Nothing to study" : "Starts studying")
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
