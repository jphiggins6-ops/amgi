//
//  ReviewSettingsView.swift
//  SettingsFeature
//
//  Created by Vladimir Gusev on 02.05.2026.
//

import SwiftUI
import Foundation
import AppCore
import AppShared
import Theme
import Sharing
import ReviewCore
import ReviewFeature
import MnemonicCore

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

    @Shared(.appStorage(ReviewPreferences.Keys.handsFreeVoice))
    private var handsFreeVoice: String = ""

    @Shared(.appStorage(ReviewPreferences.Keys.handsFreeKeepsScreenOn))
    private var handsFreeKeepsScreenOn: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.aiVoiceCards))
    private var aiVoiceCards: String = ReviewPreferences.aiVoiceCards.rawValue

    @Shared(.appStorage(ReviewPreferences.Keys.aiVoice))
    private var aiVoice: String = AIVoice.defaultVoice.rawValue

    @Shared(.appStorage(ReviewPreferences.Keys.aiVoiceRewrites))
    private var aiVoiceRewrites: Bool = true

    /// The saved Gemini key's kind, nil when there's none.
    @State private var geminiKeyKind = GeminiAPIKey.load().map(GeminiAPIKey.kind(of:))
    @State private var editsGeminiKey = false

    /// The iPhone voices installed for the phone's language.
    @State private var iPhoneVoices: [HandsFreeVoiceChoice] = []
    /// Made on the first "Hear" tap.
    @State private var preview: HandsFreeVoicePreview?
    @State private var isMakingSample = false
    @State private var sampleProblem: String?
    @State private var recordingsSize: Int64 = 0
    @State private var confirmsDeletingRecordings = false
    @State private var confirmsPreparing = false

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
            aiVoiceSection
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
                SettingsSeparator()
                SettingsToggleRow(
                    title: "Keep the screen on",
                    systemImage: "sun.max",
                    tone: .learning,
                    isOn: Binding($handsFreeKeepsScreenOn)
                )
                SettingsSeparator()
                SettingsPickerRow(
                    title: "iPhone voice",
                    systemImage: "waveform",
                    tone: .info,
                    selection: Binding($handsFreeVoice)
                ) {
                    Text("Best installed").tag("")
                    ForEach(iPhoneVoices) { voice in
                        Text(verbatim: voice.title).tag(voice.id)
                    }
                }
                SettingsSeparator()
                SettingsButtonRow(
                    title: "Hear the iPhone Voice",
                    systemImage: "play.circle",
                    tone: .info
                ) {
                    let voice = handsFreeVoice.isEmpty ? nil : handsFreeVoice
                    Task { await voicePreview.playIPhoneVoice(voice) }
                }
            }
            // Here rather than on the section's Group, which would run it
            // once for each view in it.
            .task {
                iPhoneVoices = HandsFreeVoices.choices()
                // A voice deleted from the phone since it was picked.
                if !handsFreeVoice.isEmpty, !iPhoneVoices.contains(where: { $0.id == handsFreeVoice }) {
                    $handsFreeVoice.withLock { $0 = "" }
                }
            }
            SettingsFootnote("Start it from ⋯ while reviewing. Each question is read aloud: say “show” to turn the card over and hear just the answer (the Extra isn’t read), then “again”, “hard”, “good” or “easy”. Rate straight away and the card is rated without the answer being read. “Repeat”, “undo” and “stop” work any time. With headphones you can talk over the reading; out of the speaker, wait for it to finish. The screen stays on while it runs, unless you switch that off; it also keeps going if you lock the phone.")
            SettingsFootnote("The iPhone voice reads every card the AI voice doesn’t, for free. For one that sounds far more natural, download a Premium or Enhanced voice, such as Ava or Zoe, in the Settings app: Accessibility → Read & Speak → Voices → English. Amgi uses the best one you have unless you pick one here.")
        }
    }

    private var aiVoiceSection: some View {
        Group {
            SettingsSectionHeader(title: "AI Voice")
                // On a view of its own: the group below has a dialog already.
                .confirmationDialog(
                    preparationQuestion,
                    isPresented: $confirmsPreparing,
                    titleVisibility: .visible
                ) {
                    ForEach(batchChoices, id: \.self) { count in
                        Button(batchTitle(count)) { preparation.queueBatch(count) }
                    }
                    Button("Cancel", role: .cancel) { preparation.cancelChoosing() }
                } message: {
                    Text(preparationMessage)
                }
            SettingsGroup {
                SettingsPickerRow(
                    title: "AI voice for",
                    systemImage: "sparkles",
                    tone: .mature,
                    selection: Binding($aiVoiceCards)
                ) {
                    Text("All cards").tag(AIVoiceCards.all.rawValue)
                    Text(verbatim: "Cards added since \(ReviewPreferences.aiVoiceSince.formatted(date: .abbreviated, time: .omitted))")
                        .tag(AIVoiceCards.added.rawValue)
                    Text("No cards").tag(AIVoiceCards.off.rawValue)
                }
                SettingsSeparator()
                SettingsButtonRow(
                    title: geminiKeyTitle,
                    systemImage: "key",
                    tone: .accent
                ) {
                    editsGeminiKey = true
                }
                SettingsSeparator()
                SettingsPickerRow(
                    title: "Voice",
                    systemImage: "person.wave.2",
                    tone: .link,
                    selection: Binding($aiVoice)
                ) {
                    ForEach(AIVoice.allCases) { voice in
                        Text(verbatim: voice.title).tag(voice.rawValue)
                    }
                }
                .disabled(aiVoiceIsOff)
                SettingsSeparator()
                SettingsToggleRow(
                    title: "Read questions naturally",
                    systemImage: "text.bubble",
                    tone: .learning,
                    isOn: Binding($aiVoiceRewrites)
                )
                .disabled(aiVoiceIsOff)
                SettingsSeparator()
                SettingsButtonRow(
                    title: "Hear the AI Voice",
                    systemImage: "play.circle",
                    tone: .mature,
                    isBusy: isMakingSample
                ) {
                    hearAIVoice()
                }
                .disabled(aiVoiceIsOff || isMakingSample)
                SettingsSeparator()
                preparationRows
                if recordingsSize > 0 {
                    SettingsSeparator()
                    SettingsButtonRow(
                        title: "Delete Recordings (\(ByteCountFormatter.string(fromByteCount: recordingsSize, countStyle: .file)))",
                        systemImage: "trash",
                        tone: .danger,
                        isDestructive: true
                    ) {
                        confirmsDeletingRecordings = true
                    }
                }
            }
            // Here rather than on the section's Group, which would run them
            // once for each view in it.
            .task {
                recordingsSize = CardVoiceRecordings.size()
            }
            .onDisappear {
                preview?.stop()
            }
            .sheet(isPresented: $editsGeminiKey, onDismiss: {
                geminiKeyKind = GeminiAPIKey.load().map(GeminiAPIKey.kind(of:))
            }) {
                GeminiKeySheet()
            }
            .onChange(of: preparation.phase) { _, phase in
                switch phase {
                case .choosing:
                    confirmsPreparing = true
                case .finished, .waiting:
                    recordingsSize = CardVoiceRecordings.size()
                case .idle, .checking, .preparing:
                    break
                }
            }
            .confirmationDialog(
                "Delete the AI voice’s recordings?",
                isPresented: $confirmsDeletingRecordings,
                titleVisibility: .visible
            ) {
                Button("Delete Recordings", role: .destructive) {
                    CardVoiceRecordings.deleteAll()
                    recordingsSize = 0
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("New cards are written and recorded again, and paid for again, the next time they’re read.")
            }
            if let sampleProblem {
                SettingsFootnote(sampleProblem)
            }
            switch preparation.phase {
            case .finished(let outcome):
                SettingsFootnote(outcome)
            case .waiting(_, let reason):
                SettingsFootnote(reason)
            case .idle, .checking, .choosing, .preparing:
                EmptyView()
            }
            SettingsFootnote("The cards chosen are read in a natural voice from Google Gemini; any others keep the iPhone voice, for free. With “Read questions naturally”, Gemini first rewrites each card the way a tutor would ask it: a cloze becomes a spoken question, and shorthand comes out in words. Each card is done once, the first time it’s read hands-free or ahead of time with Prepare Cards, and kept on this iPhone: about $2 for every 1,000 cards, twice that from January 2027. Prepare Cards does the cards due soonest first, a batch at a time. Google lets the Gemini voice make about 100 recordings a day on most accounts, roughly 50 cards; past that, and whenever a card isn’t ready within a few seconds, the iPhone voice reads it.")
        }
    }

    private var aiVoiceIsOff: Bool {
        aiVoiceCards == AIVoiceCards.off.rawValue
    }

    private var preparation: CardVoicePreparation { .shared }

    /// Prepare Cards, how far it's got and Stop, or what's queued.
    @ViewBuilder
    private var preparationRows: some View {
        switch preparation.phase {
        case .checking:
            SettingsButtonRow(title: "Finding the Cards Due Soonest…", systemImage: "rectangle.stack", tone: .accent, isBusy: true) {}
                .disabled(true)
            SettingsSeparator()
            stopPreparingRow
        case .preparing(let done, let total):
            SettingsButtonRow(title: "Preparing… \(done) of \(total)", systemImage: "rectangle.stack", tone: .accent, isBusy: true) {}
                .disabled(true)
            SettingsSeparator()
            stopPreparingRow
        case .waiting(let queued, _):
            SettingsValueRow(title: "Queued", value: "\(queued) cards", systemImage: "clock", tone: .accent)
            SettingsSeparator()
            SettingsButtonRow(title: "Carry On Now", systemImage: "play.circle", tone: .accent) {
                preparation.carryOn()
            }
            .disabled(aiVoiceIsOff)
            SettingsSeparator()
            prepareCardsRow
            SettingsSeparator()
            SettingsButtonRow(title: "Clear the Queue", systemImage: "xmark.circle", tone: .danger, isDestructive: true) {
                preparation.clearQueue()
            }
        case .idle, .choosing, .finished:
            prepareCardsRow
        }
    }

    private var prepareCardsRow: some View {
        SettingsButtonRow(title: "Prepare Cards…", systemImage: "rectangle.stack.badge.plus", tone: .accent) {
            preparation.check()
        }
        .disabled(aiVoiceIsOff)
    }

    private var stopPreparingRow: some View {
        SettingsButtonRow(
            title: preparation.isStopping ? "Stopping…" : "Stop",
            systemImage: "stop.circle",
            tone: .danger,
            isDestructive: true
        ) {
            preparation.stop()
        }
        .disabled(preparation.isStopping)
    }

    private var preparationQuestion: String {
        guard case .choosing(let toDo, _) = preparation.phase else { return "Prepare cards for the AI voice?" }
        return "\(toDo) cards don’t have the AI voice yet. How many should be made ready?"
    }

    /// The batches to offer: the next 50 and 100 due, when there are more,
    /// and all of them.
    private var batchChoices: [Int] {
        guard case .choosing(let toDo, _) = preparation.phase else { return [] }
        return CardVoicePreparation.batchSizes.filter { $0 < toDo } + [toDo]
    }

    private func batchTitle(_ count: Int) -> String {
        let cost = String(format: "$%.2f", Double(count) * CardVoicePreparation.costPerCard)
        guard case .choosing(let toDo, _) = preparation.phase, count < toDo else {
            return "All \(count) Cards (about \(cost))"
        }
        return "Next \(count) Due (about \(cost))"
    }

    private var preparationMessage: String {
        guard case .choosing(_, let ready) = preparation.phase else { return "" }
        let readyAlready = ready > 0 ? "\(ready) cards are ready already. " : ""
        return "\(readyAlready)They’re done soonest due first: what’s due now, then each day’s reviews and new cards, so the cards you’ll see next are ready first. Google lets the Gemini voice do about 50 cards a day; a bigger batch carries on by itself each day Amgi is open, and waits while hands-free runs. Keep Amgi open while it works: the screen stays on."
    }

    private var geminiKeyTitle: String {
        switch geminiKeyKind {
        case nil: "Add Your Gemini Key"
        case .standard: "Gemini Key: Needs Replacing"
        case .auth, .unknown: "Gemini Key: Saved ✓"
        }
    }

    private var voicePreview: HandsFreeVoicePreview {
        if let preview { return preview }
        let made = HandsFreeVoicePreview()
        preview = made
        return made
    }

    private func hearAIVoice() {
        isMakingSample = true
        sampleProblem = nil
        let voice = aiVoice
        Task {
            sampleProblem = await voicePreview.playAIVoice(voice)
            isMakingSample = false
            recordingsSize = CardVoiceRecordings.size()
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
