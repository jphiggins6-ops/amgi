//
//  ReviewView.swift
//  ReviewFeature
//
//  Created by Vladimir Gusev on 27.03.2026.
//

package import SwiftUI
import AmgiCardWeb
import Theme
import UI
import AppCore
import AppShared
import AnkiClients
package import AnkiKit
import Dependencies
import Foundation
import BrowseFeature
import TemplatesFeature
import Sharing
import ReviewCore
import SwiftUINavigation


/// Container: owns the `ReviewSession`, the review preferences, the sheet
/// selection state, and the session lifecycle (`start()`, audio-session
/// application, widget snapshot on disappear). Hands the session plus pref
/// values and sheet bindings to the pure `ReviewContent`, which is what the
/// `#Preview`s build with a stub session.
package struct ReviewView: View {
    let deckId: DeckID
    let round: StudyRound?
    let onDismiss: () -> Void

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

    @Shared(.appStorage(ReviewPreferences.Keys.showTimeLeft))
    private var showTimeLeft: Bool = true

    @Shared(.appStorage(ReaderPreferences.Keys.tapLookup))
    private var tapLookup: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.playAudioInSilentMode))
    private var playAudioInSilentMode: Bool = false

    @Environment(\.scenePhase) private var scenePhase

    @State private var session: ReviewSession
    @State private var destination: ReviewDestination?
    /// The screen can be closed twice over — Close tapped as a round's
    /// finish hands back on its own — and must hand back once.
    @State private var dismissed = false

    /// - Parameters:
    ///   - countsNewCardsAgainstHomeDecks: for a filtered deck built in place
    ///     of the normal daily queue (the Library's New button), charge the
    ///     new cards learned in it to their home decks' daily limits when
    ///     the session closes. See `ReviewSession`.
    ///   - round: for the Library's study buttons, show each card once and
    ///     count progress against the whole day. See `StudyRound`.
    package init(
        deckId: DeckID,
        countsNewCardsAgainstHomeDecks: Bool = false,
        round: StudyRound? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.deckId = deckId
        self.round = round
        self.onDismiss = onDismiss
        let session = ReviewSession(deckId: deckId)
        session.countsNewCardsAgainstHomeDecks = countsNewCardsAgainstHomeDecks
        session.showsEachCardOnce = round != nil
        session.cardsDoneBefore = round?.doneEarlierToday ?? 0
        self._session = State(initialValue: session)
    }

    package var body: some View {
        ReviewContent(
            session: session,
            showRemainingDays: showRemainingDays,
            autoMatchCardBackground: autoMatchCardBackground,
            openLinksExternally: openLinksExternally,
            cardContentAlignment: cardContentAlignment,
            tapLookup: tapLookup,
            showNextReviewTime: showNextReviewTime,
            destination: $destination,
            showTimeLeft: Binding($showTimeLeft),
            round: round,
            onDismiss: {
                guard !dismissed else { return }
                dismissed = true
                // Recorded before handing back, so the screen underneath
                // reloads its counts after the limits have been charged and
                // the problem cards have gone to the Graveyard.
                Task {
                    await session.recordNewCardsStudied()
                    await session.flagProblemCards()
                    onDismiss()
                }
            }
        )
        .task {
            ReviewAudioSession.apply(playInSilent: playAudioInSilentMode)
            session.start()
        }
        .alert(
            "Couldn't save that review",
            isPresented: Binding(
                get: { session.answerError != nil },
                set: { if !$0 { session.answerError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { session.answerError = nil }
        } message: {
            Text(session.answerError ?? "")
        }
        .onChange(of: playAudioInSilentMode) { _, newValue in
            ReviewAudioSession.apply(playInSilent: newValue)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { saveRoundProgress() }
        }
        .onDisappear {
            ReviewAudioSession.release()
            Task { await writeWidgetSnapshot() }
        }
    }

    /// Leaving the app mid-round: the Today widget and the app icon count
    /// what's left of the round now, not what was left as it began.
    private func saveRoundProgress() {
        guard let round,
              let left = session.cardsLeftInRound,
              let today = TodaySnapshotStore.read(),
              today.isCurrent(at: Date()),
              let updated = round.progress(today, cardsLeft: left)
        else { return }
        writeTodayWidget(updated)
        Task { await updateAppIcon(updated) }
    }
}
