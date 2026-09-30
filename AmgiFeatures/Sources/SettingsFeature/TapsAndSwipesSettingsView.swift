//
//  TapsAndSwipesSettingsView.swift
//  SettingsFeature
//

import SwiftUI
import AppCore
import Theme
import UI

/// Chooses what each tap area and swipe does while reviewing. The tap areas
/// are drawn as a card split three by three, so an area is picked where it
/// sits rather than by name.
struct TapsAndSwipesSettingsView: View {
    @Environment(\.palette) private var palette
    @State private var actions: [ReviewGesture: ReviewGestureAction] = TapsAndSwipesSettingsView.stored()

    var body: some View {
        SettingsPage {
            SettingsSectionHeader(title: "Tap Areas")
            tapGrid
                .padding(.horizontal, AmgiSpacing.lg)
            SettingsFootnote("Tap an area to choose what tapping there does. On the question side, any rating shows the answer instead, so a card is never rated unseen. Links, audio buttons, and words you look up work as before.")

            SettingsSectionHeader(title: "Swipes")
            SettingsGroup {
                ForEach(ReviewGesture.swipes) { gesture in
                    SettingsPickerRow(
                        title: gesture.title,
                        systemImage: Self.symbol(for: gesture),
                        tone: .accent,
                        selection: binding(for: gesture)
                    ) {
                        actionOptions
                    }
                    if gesture != ReviewGesture.swipes.last {
                        SettingsSeparator()
                    }
                }
            }
            SettingsFootnote("A swipe that scrolls a long card counts as scrolling, not as a swipe.")

            SettingsSectionHeader(title: "Defaults")
            SettingsGroup {
                SettingsButtonRow(
                    title: "Reset Taps & Swipes",
                    systemImage: "arrow.counterclockwise",
                    tone: .neutral
                ) {
                    for gesture in ReviewGesture.allCases {
                        set(gesture.defaultAction, for: gesture)
                    }
                }
            }
            SettingsFootnote("Center: Good. Middle left: Again. Swipe left: Again. Swipe right: Good. Everything else: Nothing.")
        }
        .navigationTitle("Taps & Swipes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var tapGrid: some View {
        Grid(horizontalSpacing: AmgiSpacing.sm, verticalSpacing: AmgiSpacing.sm) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        tapCell(ReviewGesture.taps[row * 3 + column])
                    }
                }
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }

    private func tapCell(_ gesture: ReviewGesture) -> some View {
        let action = actions[gesture] ?? gesture.defaultAction
        let isSet = action != .nothing
        return Menu {
            Picker(gesture.title, selection: binding(for: gesture)) {
                actionOptions
            }
        } label: {
            Text(isSet ? action.title : "—")
                .amgiFont(.caption)
                .fontWeight(isSet ? .semibold : .regular)
                .foregroundStyle(isSet ? palette.textPrimary : palette.textTertiary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .padding(AmgiSpacing.xs)
                .frame(maxWidth: .infinity, minHeight: 88)
                .background(
                    RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous)
                        .fill(isSet ? palette.accent.opacity(0.15) : palette.separator.opacity(0.25))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous)
                        .strokeBorder(palette.separator)
                )
        }
        .accessibilityLabel("\(gesture.title) tap area")
        .accessibilityValue(action.title)
    }

    @ViewBuilder
    private var actionOptions: some View {
        ForEach(ReviewGestureAction.allCases) { action in
            Text(action.title).tag(action)
        }
    }

    private func binding(for gesture: ReviewGesture) -> Binding<ReviewGestureAction> {
        Binding(
            get: { actions[gesture] ?? gesture.defaultAction },
            set: { set($0, for: gesture) }
        )
    }

    private func set(_ action: ReviewGestureAction, for gesture: ReviewGesture) {
        actions[gesture] = action
        ReviewPreferences.setGestureAction(action, for: gesture)
    }

    private static func stored() -> [ReviewGesture: ReviewGestureAction] {
        Dictionary(uniqueKeysWithValues: ReviewGesture.allCases.map {
            ($0, ReviewPreferences.gestureAction(for: $0))
        })
    }

    private static func symbol(for gesture: ReviewGesture) -> String {
        switch gesture {
        case .swipeLeft: "arrow.left"
        case .swipeRight: "arrow.right"
        case .swipeUp: "arrow.up"
        default: "arrow.down"
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        TapsAndSwipesSettingsView()
    }
}
#endif
