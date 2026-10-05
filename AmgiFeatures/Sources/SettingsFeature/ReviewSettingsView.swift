//
//  ReviewSettingsView.swift
//  SettingsFeature
//
//  Created by Vladimir Gusev on 02.05.2026.
//

import SwiftUI
import AppCore
import AppShared
import Theme
import Sharing
import ReviewCore
import ReviewFeature

struct ReviewSettingsView: View {
    @Shared(.appStorage(ReviewPreferences.Keys.openLinksExternally))
    private var openLinksExternally: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.cardContentAlignment))
    private var cardContentAlignment: String = CardWebViewContentAlignment.center.rawValue

    @Shared(.appStorage(ReviewPreferences.Keys.autoMatchCardBackground))
    private var autoMatchCardBackground: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.showRemainingDays))
    private var showRemainingDays: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.showNextReviewTime))
    private var showNextReviewTime: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.playAudioInSilentMode))
    private var playAudioInSilentMode: Bool = false

    @Shared(.appStorage(ReviewPreferences.Keys.defersRepeats))
    private var defersRepeats: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.showTimeLeft))
    private var showTimeLeft: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.handsFreeSpeed))
    private var handsFreeSpeed: String = HandsFreeSpeed.normal.rawValue

    @Shared(.appStorage(ReviewPreferences.Keys.appIconBadge))
    private var appIconBadge: String = AppIconBadge.cardsLeft.rawValue

    @Shared(.appStorage(ReviewPreferences.Keys.appIconTurnsGreen))
    private var appIconTurnsGreen: Bool = true

    var body: some View {
        SettingsPage {
            cardOrderSection
            progressSection
            appIconSection
            ProblemCardsSection()
            handsFreeSection
            gesturesSection
            cardDisplaySection
            answerButtonsSection
            audioSection
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var cardOrderSection: some View {
        Group {
            SettingsSectionHeader(title: "Card Order")
            SettingsGroup {
                SettingsToggleRow(
                    title: "See every due card before repeats",
                    systemImage: "repeat",
                    tone: .learning,
                    isOn: Binding($defersRepeats)
                )
            }
            SettingsFootnote("Cards you miss, and cards you're still learning, come back only after every other due card has had its turn. Turn off for Anki's usual order, where a card you miss can come back within minutes. The Library's Reviews and New buttons go further either way: each card once, and the ones you miss come back under Due again.")
        }
    }

    private var progressSection: some View {
        Group {
            SettingsSectionHeader(title: "Progress")
            SettingsGroup {
                SettingsToggleRow(
                    title: "Show time left",
                    systemImage: "timer",
                    tone: .info,
                    isOn: Binding($showTimeLeft)
                )
            }
            SettingsFootnote("Shown at the top while reviewing, worked out from how fast you've answered so far this session, with extra turns for new cards and for cards you miss. You can also turn it off from the ⋯ menu while reviewing.")
        }
    }

    private var appIconSection: some View {
        Group {
            SettingsSectionHeader(title: "App Icon")
            SettingsGroup {
                SettingsPickerRow(
                    title: "Number on the icon",
                    systemImage: "app.badge",
                    tone: .danger,
                    selection: Binding($appIconBadge)
                ) {
                    ForEach(AppIconBadge.allCases) { choice in
                        Text(verbatim: choice.title).tag(choice.rawValue)
                    }
                }
                SettingsSeparator()
                SettingsToggleRow(
                    title: "Turn green when done",
                    systemImage: "checkmark.seal.fill",
                    tone: .review,
                    isOn: Binding($appIconTurnsGreen)
                )
            }
            SettingsFootnote("The red number is what's left of today, as on the widget, and moves on by itself when a new day starts: an estimate until you open Amgi. Once it's all done, the stars turn green. iPhone only lets an app change its icon while it's open, with a short message each time, so they turn blue again the next time you open Amgi on a new day. No number? Turn on Badges in the Settings app → Notifications → Amgi.")
        }
        .onChange(of: appIconBadge) { _, choice in
            Task { await updateAppIcon(style: AppIconBadge(rawValue: choice) ?? .cardsLeft) }
        }
        .onChange(of: appIconTurnsGreen) { _, isOn in
            Task { await updateAppIcon(turnsGreen: isOn) }
        }
    }

    private var handsFreeSection: some View {
        Group {
            SettingsSectionHeader(title: "Hands-Free")
            SettingsGroup {
                SettingsPickerRow(
                    title: "Reading speed",
                    systemImage: "headphones",
                    tone: .accent,
                    selection: Binding($handsFreeSpeed)
                ) {
                    ForEach(HandsFreeSpeed.allCases) { speed in
                        Text(verbatim: speed.title).tag(speed.rawValue)
                    }
                }
            }
            SettingsFootnote("Start it from ⋯ while reviewing. Each question is read aloud: say “show” to turn the card over and hear just the answer (the Extra isn’t read), then “again”, “hard”, “good” or “easy”. Rate straight away and the card is rated without the answer being read. “Repeat”, “undo” and “stop” work any time. With headphones you can talk over the reading; out of the speaker, wait for it to finish. It keeps going with the screen locked.")
        }
    }

    private var gesturesSection: some View {
        Group {
            SettingsSectionHeader(title: "Gestures")
            SettingsGroup {
                SettingsRowLink(
                    title: "Taps, Swipes & Shake",
                    systemImage: "hand.tap",
                    tone: .accent
                ) {
                    TapsAndSwipesSettingsView()
                }
            }
        }
    }

    private var cardDisplaySection: some View {
        Group {
            SettingsSectionHeader(title: "Card Display")
            SettingsGroup {
                SettingsToggleRow(
                    title: "Match toolbar to card background",
                    systemImage: "paintbrush",
                    tone: .mature,
                    isOn: Binding($autoMatchCardBackground)
                )
                SettingsSeparator()
                SettingsToggleRow(
                    title: "Open links externally",
                    systemImage: "arrow.up.right.square",
                    tone: .accent,
                    isOn: Binding($openLinksExternally)
                )
                SettingsSeparator()
                SettingsPickerRow(
                    title: "Content alignment",
                    systemImage: "arrow.up.and.down.text.horizontal",
                    tone: .link,
                    selection: Binding($cardContentAlignment)
                ) {
                    Text("Center").tag(CardWebViewContentAlignment.center.rawValue)
                    Text("Top").tag(CardWebViewContentAlignment.top.rawValue)
                }
            }
        }
    }

    private var answerButtonsSection: some View {
        Group {
            SettingsSectionHeader(title: "Answer Buttons")
            SettingsGroup {
                SettingsToggleRow(
                    title: "Show remaining counts",
                    systemImage: "number",
                    tone: .review,
                    isOn: Binding($showRemainingDays)
                )
                SettingsSeparator()
                SettingsToggleRow(
                    title: "Show next review time",
                    systemImage: "clock",
                    tone: .info,
                    isOn: Binding($showNextReviewTime)
                )
            }
        }
    }

    private var audioSection: some View {
        Group {
            SettingsSectionHeader(title: "Audio")
            SettingsGroup {
                SettingsToggleRow(
                    title: "Play audio in silent mode",
                    systemImage: "speaker.wave.2",
                    tone: .learning,
                    isOn: Binding($playAudioInSilentMode)
                )
            }
        }
    }
}

#if DEBUG

#Preview {
    NavigationStack {
        ReviewSettingsView()
    }
}
#endif
