//
//  ProblemCardsSection.swift
//  SettingsFeature
//

import OSLog
import SwiftUI
import AppCore
import AnkiClients
import AnkiKit
import Dependencies
import ReviewCore
import Sharing
import Theme

/// Settings → Review → Graveyard: how many times a card is forgotten
/// before the next miss flags it for the Graveyard, and a one-off sweep of
/// the cards that are already past that.
struct ProblemCardsSection: View {
    @Shared(.appStorage(ReviewPreferences.Keys.problemCardLapses))
    private var lapses: Int = ReviewPreferences.defaultProblemCardLapses

    @State private var sweep = ProblemCardsSweep()

    var body: some View {
        Group {
            SettingsSectionHeader(title: "Graveyard")
            SettingsGroup {
                SettingsPickerRow(
                    title: "Flag cards forgotten",
                    systemImage: "flag.2.crossed",
                    tone: .danger,
                    selection: Binding($lapses)
                ) {
                    ForEach(ReviewPreferences.problemCardLapsesChoices, id: \.self) { choice in
                        Text(verbatim: Self.title(choice)).tag(choice)
                    }
                }
                SettingsSeparator()
                SettingsButtonRow(
                    title: "Flag Cards Already Forgotten That Often",
                    systemImage: "tray.and.arrow.down",
                    tone: .neutral,
                    isBusy: sweep.isWorking
                ) {
                    Task { await sweep.find(threshold: lapses) }
                }
                .disabled(lapses == 0 || sweep.isWorking)
            }
            SettingsFootnote("A card you keep forgetting is usually badly written. Once a card has been forgotten this many times, missing it again flags it orange, and it waits in the Graveyard to be fixed. Red stays yours for cards you flag yourself.")
        }
        .confirmationDialog(
            sweep.confirmTitle,
            isPresented: Binding(get: { sweep.found != nil }, set: { if !$0 { sweep.found = nil } }),
            titleVisibility: .visible
        ) {
            Button(sweep.sendTitle) {
                Task { await sweep.send() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            sweep.resultTitle,
            isPresented: Binding(get: { sweep.result != nil }, set: { if !$0 { sweep.result = nil } })
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    static func title(_ lapses: Int) -> String {
        lapses == 0 ? "Off" : "\(lapses) times"
    }
}

/// Finds the cards already forgotten `threshold` times or more and flags
/// them orange on confirmation.
@Observable
@MainActor
final class ProblemCardsSweep {
    /// Cards found, waiting for confirmation.
    var found: [CardID]?
    /// What happened, for the closing alert.
    var result: Outcome?
    private(set) var isWorking = false
    @ObservationIgnored private var threshold = 0

    enum Outcome: Equatable {
        case nothingFound
        case sent(Int)
    }

    @ObservationIgnored @Dependency(\.cardClient) private var cardClient

    func find(threshold: Int) async {
        guard threshold > 0, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        self.threshold = threshold
        let ids = (try? await cardClient.search(ProblemCardRule.existingSearch(threshold: threshold))) ?? []
        if ids.isEmpty {
            result = .nothingFound
        } else {
            found = ids
        }
    }

    func send() async {
        guard let ids = found, !isWorking else { return }
        found = nil
        isWorking = true
        defer { isWorking = false }
        var sent = 0
        for id in ids {
            do {
                try await cardClient.flag(id, ProblemCardRule.flag)
                sent += 1
            } catch {
                Log.review.error("Flagging \(id.rawValue) failed: \(error)")
            }
        }
        result = .sent(sent)
    }

    var confirmTitle: String {
        let count = found?.count ?? 0
        let cards = count == 1 ? "1 card has" : "\(count) cards have"
        return "\(cards) been forgotten \(threshold) times or more. Flag them orange for the Graveyard?"
    }

    var sendTitle: String {
        (found?.count ?? 0) == 1 ? "Flag 1 Card" : "Flag \(found?.count ?? 0) Cards"
    }

    var resultTitle: String {
        switch result {
        case .nothingFound?: "No cards have been forgotten that often."
        case .sent(let count)?: count == 1 ? "1 card is waiting in the Graveyard." : "\(count) cards are waiting in the Graveyard."
        case nil: ""
        }
    }
}
