//
//  TodaySummary.swift
//  DecksFeature
//

import OSLog
import SwiftUI
import AppCore
import AnkiClients
import AnkiKit
import Dependencies
import Foundation
import MnemonicCore
import Theme

/// The end of the day, once today's minimum is done: how long it took, how
/// much was right, and the cards that gave the most trouble, which one tap
/// sends to the Graveyard.
@Observable
@MainActor
final class TodaySummaryModel {
    /// A card missed today, as the summary lists it.
    struct HardCard: Identifiable, Equatable, Sendable {
        let cardId: CardID
        /// The note's first field, as one readable line.
        let front: String
        /// How often it's been forgotten after it was learned.
        let lapses: Int

        var id: CardID { cardId }
    }

    struct Summary: Equatable, Sendable {
        var answers = 0
        var correct = 0
        var milliseconds = 0
        var hardest: [HardCard] = []
    }

    enum State: Equatable {
        case loading
        case loaded(Summary)
        case failed(String)
    }

    private(set) var state: State = .loading
    /// The hardest cards to send; all of them until some are unticked.
    var selected: Set<CardID> = []
    /// How many were sent, once they have been.
    private(set) var sent: Int?
    private(set) var isSending = false

    @ObservationIgnored @Dependency(\.statsClient) private var statsClient
    @ObservationIgnored @Dependency(\.cardClient) private var cardClient
    @ObservationIgnored @Dependency(\.noteClient) private var noteClient

    /// Cards answered Again today, not already flagged, outside "p".
    static let missedTodaySearch = "rated:1:1 flag:0 -deck:p"
    static let hardestCount = 5
    /// Anki's red flag: the user's own "this card is defective".
    static let graveyardFlag: UInt32 = 1

    func load() async {
        do {
            let today = try await statsClient.fetchGraphs("", 1).today
            var summary = Summary(
                answers: today.answerCount,
                correct: today.correctCount,
                milliseconds: today.answerMillis
            )
            var missed: [CardRecord] = []
            for id in try await cardClient.search(Self.missedTodaySearch) {
                if let card = try? await cardClient.fetch(id) { missed.append(card) }
            }
            for card in Self.hardest(missed) {
                let note = try? await noteClient.fetch(card.nid)
                let firstField = note?.flds.components(separatedBy: "\u{1f}").first ?? ""
                summary.hardest.append(HardCard(
                    cardId: card.id,
                    front: MnemonicText.summary(firstField, limit: 100),
                    lapses: Int(card.lapses)
                ))
            }
            selected = Set(summary.hardest.map(\.cardId))
            state = .loaded(summary)
        } catch {
            Log.decks.error("Today's summary failed: \(error)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Flags the ticked cards red, which puts them in the Graveyard.
    func sendToGraveyard() async {
        guard !isSending, !selected.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        var count = 0
        for id in selected {
            do {
                try await cardClient.flag(id, Self.graveyardFlag)
                count += 1
            } catch {
                Log.decks.error("Flagging \(id.rawValue) failed: \(error)")
            }
        }
        sent = count
    }

    /// The cards missed today that have been forgotten most often in all,
    /// then the most reviewed: trouble that keeps coming back.
    static func hardest(_ cards: [CardRecord], limit: Int = hardestCount) -> [CardRecord] {
        Array(cards.sorted { lhs, rhs in
            if lhs.lapses != rhs.lapses { return lhs.lapses > rhs.lapses }
            if lhs.reps != rhs.reps { return lhs.reps > rhs.reps }
            return lhs.id.rawValue < rhs.id.rawValue
        }.prefix(limit))
    }

    /// "52 min", "1 h 5 min", "under a minute".
    static func duration(milliseconds: Int) -> String {
        let minutes = Int((Double(milliseconds) / 60_000).rounded())
        guard minutes >= 1 else { return "under a minute" }
        guard minutes >= 60 else { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "–" }
        return "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
    }
}

/// The summary as a sheet over the Library.
struct TodaySummarySheet: View {
    @State private var model = TodaySummaryModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Load Today", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    }
                case .loaded(let summary):
                    content(summary)
                }
            }
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await model.load() }
    }

    private func content(_ summary: TodaySummaryModel.Summary) -> some View {
        List {
            Section {
                VStack(spacing: AmgiSpacing.md) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(palette.positive)
                        .accessibilityHidden(true)
                    Text("Done for today")
                        .amgiFont(.sectionHeading)
                        .foregroundStyle(palette.textPrimary)
                    HStack(spacing: AmgiSpacing.sm) {
                        stat(TodaySummaryModel.duration(milliseconds: summary.milliseconds), "studied")
                        stat(TodaySummaryModel.percent(summary.correct, of: summary.answers), "right")
                        stat("\(summary.answers)", summary.answers == 1 ? "answer" : "answers")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AmgiSpacing.sm)
            }

            hardestSection(summary.hardest)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: value)
                .amgiFont(.bodyEmphasis, .monospacedDigits)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(verbatim: label)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AmgiSpacing.sm)
        .background(palette.separator.opacity(0.25), in: RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func hardestSection(_ cards: [TodaySummaryModel.HardCard]) -> some View {
        if cards.isEmpty {
            Section {
                Label("You didn't miss a single card today.", systemImage: "star.fill")
                    .foregroundStyle(palette.textSecondary)
            }
        } else {
            Section {
                ForEach(cards) { card in
                    Button {
                        if model.selected.contains(card.cardId) {
                            model.selected.remove(card.cardId)
                        } else {
                            model.selected.insert(card.cardId)
                        }
                    } label: {
                        HardCardRow(card: card, isSelected: model.selected.contains(card.cardId))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.sent != nil)
                }
            } header: {
                Text("Hardest today")
            } footer: {
                Text("Cards you missed today that you've forgotten most often. Sending them flags them red, so they wait in the Graveyard to be fixed.")
            }

            Section {
                if let sent = model.sent {
                    Label(sentMessage(sent), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(palette.positive)
                } else {
                    Button {
                        Task { await model.sendToGraveyard() }
                    } label: {
                        Label(sendTitle, systemImage: "flag.2.crossed")
                    }
                    .disabled(model.selected.isEmpty || model.isSending)
                }
            }
        }
    }

    private var sendTitle: String {
        let count = model.selected.count
        return count == 1 ? "Send 1 Card to the Graveyard" : "Send \(count) Cards to the Graveyard"
    }

    private func sentMessage(_ count: Int) -> String {
        count == 1 ? "1 card sent to the Graveyard" : "\(count) cards sent to the Graveyard"
    }
}

private struct HardCardRow: View {
    @Environment(\.palette) private var palette
    let card: TodaySummaryModel.HardCard
    let isSelected: Bool

    var body: some View {
        HStack(spacing: AmgiSpacing.md) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? palette.accent : palette.textTertiary)
                .imageScale(.large)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: card.front.isEmpty ? "(empty card)" : card.front)
                    .amgiFont(.body)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(2)
                Text(verbatim: lapsesText)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(traits)
    }

    private var traits: AccessibilityTraits {
        isSelected ? [.isButton, .isSelected] : [.isButton]
    }

    private var lapsesText: String {
        switch card.lapses {
        case 0: "Missed today while learning"
        case 1: "Forgotten once"
        default: "Forgotten \(card.lapses) times"
        }
    }
}
