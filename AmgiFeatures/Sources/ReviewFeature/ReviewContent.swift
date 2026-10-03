//
//  ReviewContent.swift
//  ReviewFeature
//
//  Created by Vladimir Gusev on 27.03.2026.
//

import SwiftUI
import Foundation
import AmgiCardWeb
import Theme
import UI
import AppCore
import AppShared
import AnkiClients
import AnkiKit
import Dependencies
import BrowseFeature
import TemplatesFeature
import Sharing
import ReviewCore
import MnemonicCore
import SwiftUINavigation

// MARK: - Content

/// Pure render surface for a review session: the card/finished views,
/// toolbar, and edit/lookup sheets. Takes the session read-only plus pref
/// values and sheet bindings — no lifecycle, so a `#Preview` renders it
/// with a stub session and no backend.
struct ReviewContent: View {
    let session: ReviewSession
    let showRemainingDays: Bool
    let autoMatchCardBackground: Bool
    let openLinksExternally: Bool
    let cardContentAlignment: String
    let tapLookup: Bool
    let showNextReviewTime: Bool
    @Binding var destination: ReviewDestination?
    /// The estimated time left under the progress bar. A binding so the ⋯
    /// menu can switch it off right there.
    @Binding var showTimeLeft: Bool
    /// Set for the Library's study buttons, whose sessions end in a short
    /// celebration and a return to the Library.
    var round: StudyRound? = nil
    let onDismiss: () -> Void

    @Environment(\.palette) private var palette
    /// Supplied by the app root — see `EnvironmentValues.lookupPopup`. Keeping
    /// the popup itself out of this target is what keeps it off the Cxx chain.
    @Environment(\.lookupPopup) private var lookupPopup
    @State private var cardActions = CardContextMenuModel()
    @State private var confirmDeleteNote = false
    @State private var lookupHighlight = LookupHighlight()
    /// Bumped when a ✨ idea is saved; drives the confirmation haptic.
    @State private var mnemonicSavedCount = 0
    /// Bumped when a tap or swipe flags a card, which otherwise shows only
    /// as the menu icon's colour.
    @State private var gestureFlagCount = 0
    #if canImport(UIKit)
    /// Reads cards aloud and takes answers by voice; see `HandsFreeController`.
    @State private var handsFree = HandsFreeController()
    #endif

    private var keyboardActive: Bool {
        destination == nil && !confirmDeleteNote
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if !canImport(UIKit)
                macChrome
                #endif

                if showRemainingDays && session.startError == nil {
                    ReviewProgressBar(session: session)
                }

                if showTimeLeft && session.startError == nil && !session.isFinished {
                    ReviewTimeLeft(session: session)
                }

                #if canImport(UIKit)
                if handsFree.isOn || handsFree.problem != nil {
                    HandsFreeBanner(controller: handsFree)
                }
                #endif

                if let startError = session.startError {
                    ReviewStartFailureView(message: startError) { session.start() }
                } else if session.isFinished {
                    if let round {
                        RoundFinishedView(round: round, onDone: onDismiss)
                    } else {
                        ReviewFinishedView(session: session, onDone: onDismiss)
                    }
                } else {
                    ReviewCardArea(
                        session: session,
                        openLinksExternally: openLinksExternally,
                        cardContentAlignment: cardContentAlignment,
                        tapLookup: tapLookup,
                        showNextReviewTime: showNextReviewTime,
                        lookupHighlight: lookupHighlight,
                        shortcutsEnabled: keyboardActive,
                        lookupQuery: $destination.lookupText,
                        onGesture: { perform($0) },
                        onExplain: { explain() }
                    )
                }
            }
            .background(palette.background)
            .reviewHaptics(session: session)
            .sensoryFeedback(.success, trigger: mnemonicSavedCount)
            .sensoryFeedback(.selection, trigger: gestureFlagCount)
            #if canImport(UIKit)
            .onReceive(NotificationCenter.default.publisher(for: .amgiDeviceDidShake)) { _ in
                perform(.shake)
            }
            // Hands-free gives way to anything opened over the card, and
            // ends with the screen.
            .onChange(of: destination != nil) { _, opened in
                if opened { handsFree.stop() }
            }
            .onDisappear { handsFree.stop() }
            #endif
            .navigationBarTitleDisplayMode(.inline)
            #if canImport(UIKit)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarLeading) {
                    ReviewEditButton(session: session, destination: $destination, shortcutEnabled: keyboardActive)
                }
                ToolbarItem(placement: .principal) {
                    ReviewDeckTitle(session: session)
                }
                if showRemainingDays {
                    ToolbarItem(placement: .topBarTrailing) {
                        ReviewPositionCounter(session: session)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    MnemonicCaptureButton(session: session, destination: $destination)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ReviewUndoButton(session: session, shortcutEnabled: keyboardActive)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    CardActionsMenu(
                        session: session,
                        cardActions: cardActions,
                        destination: $destination,
                        confirmDeleteNote: $confirmDeleteNote,
                        showTimeLeft: $showTimeLeft,
                        onExplain: { explain() },
                        isHandsFreeOn: handsFree.isOn,
                        onToggleHandsFree: { toggleHandsFree() }
                    )
                }
            }
            #endif
            .cardActionPresentations(
                model: cardActions,
                cardId: session.currentCardId,
                noteId: session.currentNote?.id,
                confirmDeleteNote: $confirmDeleteNote
            )
            #if canImport(UIKit)
            .cardChromeToolbar(session: session, enabled: autoMatchCardBackground)
            #endif
            .sheet(item: $destination.editNote) { note in
                NavigationStack {
                    NoteEditorView(note: note) {
                        Task { await session.refreshAfterEdit() }
                    }
                }
            }
            .sheet(item: $destination.explain) { card in
                ExplainSheet(card: card)
            }
            .sheet(item: $destination.captureMnemonic) { note in
                MnemonicCaptureSheet(note: note) {
                    mnemonicSavedCount += 1
                    // The idea is now in the note, so the session's cached
                    // copy is stale. Refresh it, or a later Edit Note would
                    // save the old copy back over the idea.
                    Task { await session.refreshAfterEdit() }
                }
            }
            .sheet(item: $destination.editTemplate) { target in
                NavigationStack {
                    TemplateEditorView(
                        notetypeId: target.notetypeId,
                        initialTemplateIndex: target.ordinal,
                        mode: .currentCard,
                        onSaved: { await session.refreshAfterEdit() }
                    )
                }
            }
            .sheet(isPresented: Binding($destination.lookup), onDismiss: { lookupHighlight.clear() }) {
                if let lookupPopup {
                    lookupPopup.popup(
                        query: destination.lookupText ?? "",
                        onMatched: { lookupHighlight.show(matched: $0) },
                        onDismiss: { destination = nil }
                    )
                }
            }
        }
    }

    /// Runs the action chosen for this tap area or swipe in Settings.
    /// Ignored while a sheet or dialog is up, while an answer is being typed
    /// (a tap meant to dismiss the keyboard must not reveal it), and for a
    /// moment after the card changes or turns over
    /// (`ReviewSession.acceptsGestures`).
    private func perform(_ gesture: ReviewGesture) {
        guard keyboardActive, session.acceptsGestures, !session.requiresTypedAnswerInput else { return }
        let action = ReviewPreferences.gestureAction(for: gesture)
        if let rating = action.rating {
            // Never rate an unseen answer: on the question side, show it.
            if session.showAnswer {
                session.answer(rating: rating)
            } else {
                session.revealAnswer()
            }
            return
        }
        switch action {
        case .showAnswer:
            session.revealAnswer()
        case .undo:
            session.undo()
        case .replayAudio:
            session.bumpReplayRequest()
        case .editNote:
            destination = session.currentNote.map(ReviewDestination.editNote)
        case .visualMnemonic:
            destination = session.currentNote.map(ReviewDestination.captureMnemonic)
        case .explain:
            // Explaining gives the answer away, so show it too.
            session.revealAnswer()
            explain()
        case .handsFree:
            toggleHandsFree()
        case .flagRed, .flagOrange, .flagGreen, .flagBlue:
            guard let cardId = session.currentCardId, let flag = action.flag else { return }
            Task {
                await cardActions.toggleFlag(cardId, flag)
                gestureFlagCount += 1
            }
        case .nothing, .again, .hard, .good, .easy:
            break
        }
    }

    private func toggleHandsFree() {
        #if canImport(UIKit)
        if handsFree.isOn {
            handsFree.stop()
        } else {
            handsFree.start(session: session, finishMessage: round?.finishTitle ?? "That's all for now")
        }
        #endif
    }

    /// Opens Explain on the card as its two sides show it.
    private func explain() {
        guard session.currentCardId != nil else { return }
        destination = .explain(CardExplanation.Card(
            questionHTML: session.frontHTML,
            answerHTML: session.backHTML,
            deckName: session.deckName
        ))
    }

    #if !canImport(UIKit)
    @ViewBuilder
    private var macChrome: some View {
        HStack(spacing: 12) {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close")
            ReviewEditButton(session: session, destination: $destination, shortcutEnabled: keyboardActive)

            Spacer()
            ReviewDeckTitle(session: session)
            Spacer()

            if showRemainingDays {
                ReviewPositionCounter(session: session)
            }
            MnemonicCaptureButton(session: session, destination: $destination)
            ReviewUndoButton(session: session, shortcutEnabled: keyboardActive)
            CardActionsMenu(
                session: session,
                cardActions: cardActions,
                destination: $destination,
                confirmDeleteNote: $confirmDeleteNote,
                showTimeLeft: $showTimeLeft,
                onExplain: { explain() }
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.surface)

        Divider()
    }
    #endif
}

// MARK: - Toolbar chrome

private struct CardChromeToolbar: ViewModifier {
    let session: ReviewSession
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .toolbarBackground(
                enabled ? session.cardChromeColor : Color.clear,
                for: .navigationBar
            )
            .toolbarBackground(
                enabled ? .visible : .automatic,
                for: .navigationBar
            )
            .toolbarColorScheme(
                enabled && session.cardChromeIsDark ? .dark : .light,
                for: .navigationBar
            )
    }
}

private struct ReviewHaptics: ViewModifier {
    let session: ReviewSession

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(trigger: session.answerTapCount) { _, _ in
                session.tappedRating == .again
                    ? .impact(weight: .medium)
                    : .impact(weight: .light)
            }
            .sensoryFeedback(.impact(flexibility: .soft), trigger: session.undoneCount)
            .sensoryFeedback(trigger: session.isFinished) { _, finished in
                finished ? .success : nil
            }
    }
}

private extension View {
    func cardChromeToolbar(session: ReviewSession, enabled: Bool) -> some View {
        modifier(CardChromeToolbar(session: session, enabled: enabled))
    }

    func reviewHaptics(session: ReviewSession) -> some View {
        modifier(ReviewHaptics(session: session))
    }
}

// MARK: - Toolbar items

private struct ReviewDeckTitle: View {
    let session: ReviewSession

    @Environment(\.palette) private var palette

    var body: some View {
        Text(session.deckName)
            .amgiFont(.bodyEmphasis)
            .foregroundStyle(palette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

private struct ReviewPositionCounter: View {
    let session: ReviewSession

    @Environment(\.palette) private var palette

    var body: some View {
        let position = session.cardPosition
        let total = max(session.sessionTotal, 1)
        Text("\(position)/\(total)")
            .amgiFont(.caption)
            .monospacedDigit()
            .foregroundStyle(palette.textSecondary)
            .contentTransition(.numericText())
            .animation(AmgiMotion.quick, value: position)
            .accessibilityLabel("Card \(position) of \(total)")
    }
}

private struct ReviewUndoButton: View {
    let session: ReviewSession
    let shortcutEnabled: Bool

    var body: some View {
        Button {
            session.undo()
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .disabled(!session.canUndo)
        .keyboardShortcut(shortcutEnabled ? KeyboardShortcut("z", modifiers: .command) : nil)
        .accessibilityLabel("Undo")
    }
}

/// Opens the card's note for editing in one tap. Also in the ⋯ menu.
private struct ReviewEditButton: View {
    let session: ReviewSession
    @Binding var destination: ReviewDestination?
    let shortcutEnabled: Bool

    var body: some View {
        Button {
            destination = session.currentNote.map(ReviewDestination.editNote)
        } label: {
            Image(systemName: "pencil")
        }
        .disabled(session.currentNote == nil)
        .keyboardShortcut(shortcutEnabled ? KeyboardShortcut("e", modifiers: .command) : nil)
        .accessibilityLabel("Edit Note")
    }
}

private struct MnemonicCaptureButton: View {
    let session: ReviewSession
    @Binding var destination: ReviewDestination?

    var body: some View {
        Button {
            destination = session.currentNote.map(ReviewDestination.captureMnemonic)
        } label: {
            Image(systemName: "sparkles")
        }
        .disabled(session.currentNote == nil)
        .accessibilityLabel("Visual mnemonic")
    }
}

// MARK: - Card actions

private struct CardActionsMenu: View {
    let session: ReviewSession
    let cardActions: CardContextMenuModel
    @Binding var destination: ReviewDestination?
    @Binding var confirmDeleteNote: Bool
    @Binding var showTimeLeft: Bool
    let onExplain: () -> Void
    var isHandsFreeOn = false
    /// Nil where hands-free isn't available.
    var onToggleHandsFree: (() -> Void)? = nil

    @Environment(\.palette) private var palette

    private var handsFreeTitle: String {
        isHandsFreeOn ? "Stop Hands-Free" : "Hands-Free Mode"
    }

    private var timeLeftToggleTitle: String {
        showTimeLeft ? "Hide Time Left" : "Show Time Left"
    }

    var body: some View {
        Menu {
            if let cardId = session.currentCardId {
                CardFlagPicker(model: cardActions, cardId: cardId)
            }

            Section {
                Button {
                    destination = session.currentNote.map(ReviewDestination.editNote)
                } label: {
                    Label("Edit Note", systemImage: "pencil")
                }
                .disabled(session.currentNote == nil)

                Button {
                    destination = session.currentTemplateTarget.map(ReviewDestination.editTemplate)
                } label: {
                    Label("Edit Template", systemImage: "square.and.pencil")
                }
                .disabled(session.currentTemplateTarget == nil)

                Button {
                    // Empty initial query opens the popup focused for typing.
                    // Future enhancement: forward CardWebView text-selection so
                    // the query is pre-populated.
                    destination = .lookup("")
                } label: {
                    Label("Look Up", systemImage: "character.book.closed")
                }

                Button {
                    onExplain()
                } label: {
                    Label("Explain with AI", systemImage: "lightbulb")
                }
                .disabled(session.currentCardId == nil)

                Button {
                    if session.isAudioPlaying {
                        session.bumpStopAudioRequest()
                    } else {
                        session.bumpReplayRequest()
                    }
                } label: {
                    Label(
                        session.isAudioPlaying ? "Stop Audio" : "Replay Audio",
                        systemImage: session.isAudioPlaying ? "pause.circle" : "play.circle"
                    )
                }
                .disabled(session.currentNote == nil)
            }

            if let onToggleHandsFree {
                Section {
                    Button(action: onToggleHandsFree) {
                        Label(handsFreeTitle, systemImage: "headphones")
                    }
                }
            }

            Section {
                Button {
                    showTimeLeft.toggle()
                } label: {
                    Label(timeLeftToggleTitle, systemImage: "timer")
                }
            }

            if let cardId = session.currentCardId {
                CardActionSections(
                    model: cardActions,
                    cardId: cardId,
                    noteId: session.currentNote?.id,
                    confirmDeleteNote: $confirmDeleteNote
                )
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(
                    cardActions.currentFlag == 0
                        ? palette.accent
                        : CardFlag.color(cardActions.currentFlag)
                )
        }
        .accessibilityLabel("Card actions")
    }
}

// MARK: - Progress

private struct ReviewProgressBar: View {
    let session: ReviewSession

    @Environment(\.palette) private var palette

    var body: some View {
        let fraction = min(max(session.progressFraction, 0), 1)
        ZStack(alignment: .leading) {
            Capsule().fill(palette.separator)
            Capsule()
                .fill(palette.accent)
                .scaleEffect(x: fraction, y: 1, anchor: .leading)
        }
        .frame(height: 3)
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .animation(AmgiMotion.standard, value: fraction)
    }
}

// MARK: - Time left

/// "About 12 min left · done around 3:42 PM", from how fast this session's
/// cards have been answered (`ReviewSession.estimatedSecondsLeft`). Ticks
/// each minute, so the finish time moves on while a card stays up.
private struct ReviewTimeLeft: View {
    let session: ReviewSession

    @Environment(\.palette) private var palette

    var body: some View {
        let secondsLeft = session.estimatedSecondsLeft
        TimelineView(.everyMinute) { context in
            HStack(spacing: 4) {
                Image(systemName: "timer")
                    .accessibilityHidden(true)
                Text(verbatim: ReviewPace.summary(secondsLeft: secondsLeft, now: context.date))
            }
            .amgiFont(.caption, .monospacedDigits)
            .foregroundStyle(palette.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Terminal states

private struct ReviewStartFailureView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Start Reviewing", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: onRetry)
                .buttonStyle(AmgiPrimaryButtonStyle())
        }
    }
}

private struct ReviewFinishedView: View {
    let session: ReviewSession
    let onDone: () -> Void

    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 64

    var body: some View {
        VStack(spacing: AmgiSpacing.lg) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: glyphSize))
                .foregroundStyle(palette.positive)
                .accessibilityHidden(true)   // "Congratulations!" below says it
            Text("Congratulations!")
                .amgiFont(.sectionHeading)
                .foregroundStyle(palette.textPrimary)
            Text("You've reviewed \(session.sessionStats.reviewed) cards")
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)
            if session.sessionStats.reviewed > 0 {
                Text("Accuracy: \(Int(session.sessionStats.accuracy * 100))%")
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
            Button("Done", action: onDone)
                .buttonStyle(AmgiPrimaryButtonStyle())
                .padding()
        }
    }
}

/// The end of a Library round: "Done for today" (or how far the day has
/// got) for a couple of seconds, then back to the Library on its own. A
/// tap anywhere goes back at once.
private struct RoundFinishedView: View {
    let round: StudyRound
    let onDone: () -> Void

    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 76
    @State private var shown = false

    var body: some View {
        VStack(spacing: AmgiSpacing.lg) {
            Spacer()
            Image(systemName: round.finishSymbol)
                .font(.system(size: glyphSize))
                .foregroundStyle(palette.positive)
                .scaleEffect(shown ? 1 : 0.6)
                .opacity(shown ? 1 : 0)
                .accessibilityHidden(true)
            Text(verbatim: round.finishTitle)
                .amgiFont(.sectionHeading)
                .foregroundStyle(palette.textPrimary)
            Text(verbatim: round.finishMessage)
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AmgiSpacing.lg)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDone)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Goes back to the Library")
        .accessibilityAction { onDone() }
        .task {
            withAnimation(AmgiMotion.momentum) { shown = true }
            // Cancelled if the screen closes first, and then hands nothing back.
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            onDone()
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Question") {
    ReviewContent(
        session: .preview(showAnswer: false),
        showRemainingDays: true,
        autoMatchCardBackground: false,
        openLinksExternally: true,
        cardContentAlignment: CardWebViewContentAlignment.center.rawValue,
        tapLookup: true,
        showNextReviewTime: true,
        destination: .constant(nil),
        showTimeLeft: .constant(true),
        onDismiss: {}
    )
}

#Preview("Answer") {
    ReviewContent(
        session: .preview(showAnswer: true),
        showRemainingDays: true,
        autoMatchCardBackground: false,
        openLinksExternally: true,
        cardContentAlignment: CardWebViewContentAlignment.center.rawValue,
        tapLookup: true,
        showNextReviewTime: true,
        destination: .constant(nil),
        showTimeLeft: .constant(true),
        onDismiss: {}
    )
}

#Preview("Done for today") {
    ReviewContent(
        session: .preview(isFinished: true),
        showRemainingDays: true,
        autoMatchCardBackground: false,
        openLinksExternally: true,
        cardContentAlignment: CardWebViewContentAlignment.center.rawValue,
        tapLookup: true,
        showNextReviewTime: true,
        destination: .constant(nil),
        showTimeLeft: .constant(true),
        round: StudyRound(kind: .reviews, doneEarlierToday: 120, finishesTheDay: true),
        onDismiss: {}
    )
}

#Preview("Finished") {
    ReviewContent(
        session: .preview(isFinished: true),
        showRemainingDays: true,
        autoMatchCardBackground: false,
        openLinksExternally: true,
        cardContentAlignment: CardWebViewContentAlignment.center.rawValue,
        tapLookup: true,
        showNextReviewTime: true,
        destination: .constant(nil),
        showTimeLeft: .constant(true),
        onDismiss: {}
    )
}
#endif
