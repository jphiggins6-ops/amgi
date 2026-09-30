//
//  MnemonicInboxModel.swift
//  DecksFeature
//

import Dependencies
import Foundation
import MnemonicCore
import Observation

struct MnemonicInboxRow: Identifiable {
    var item: PendingMnemonic
    /// What's in the text box right now — may differ from what drew the draft.
    var prompt: String
    var draft: MnemonicImage?
    /// The description that produced `draft`; approval records this, not
    /// whatever has been typed since.
    var draftPrompt: String?
    var isWorking = false
    var errorMessage: String?

    var id: PendingMnemonic.ID { item.id }

    /// The text changed after the draft was made, so the picture no longer
    /// matches what's written.
    var draftIsStale: Bool {
        guard let draftPrompt else { return false }
        return draftPrompt != prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The review-later half: every waiting idea, a draft picture per idea on
/// request, and approve / discard. Drafts live only here, in memory — nothing
/// reaches a card until Approve.
@Observable
@MainActor
final class MnemonicInboxModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: LoadState = .loading
    private(set) var rows: [MnemonicInboxRow] = []
    /// Bumped per approval; drives the success haptic.
    private(set) var approvedCount = 0

    @ObservationIgnored @Dependency(\.mnemonicClient) private var client
    @ObservationIgnored @Dependency(\.mnemonicImageGenerator) private var generator

    /// A refresh keeps any typing and drafts for ideas that are still
    /// waiting — pulling to refresh shouldn't throw away work.
    func load() async {
        do {
            let items = try await client.pending()
            let previous = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rows = items.map { item -> MnemonicInboxRow in
                guard var kept = previous[item.id] else {
                    return MnemonicInboxRow(item: item, prompt: item.idea)
                }
                kept.item = item
                return kept
            }
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func setPrompt(_ prompt: String, for id: MnemonicInboxRow.ID) {
        guard let index = index(of: id) else { return }
        rows[index].prompt = prompt
    }

    func generate(_ id: MnemonicInboxRow.ID) async {
        guard let index = index(of: id), !rows[index].isWorking else { return }
        let prompt = rows[index].prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            rows[index].errorMessage = "Describe the picture first."
            return
        }
        rows[index].isWorking = true
        rows[index].errorMessage = nil
        var item = rows[index].item

        do {
            // Save an edited description onto the card before spending
            // anything on it, so leaving this screen can't lose the edit.
            if prompt != item.idea {
                try await client.updateIdea(item, prompt)
                item.idea = prompt
            }
            let image = try await generator.generate(MnemonicImageRequest(idea: prompt))
            update(id) {
                $0.item = item
                $0.draft = image
                $0.draftPrompt = prompt
                $0.isWorking = false
            }
        } catch {
            update(id) {
                $0.item = item
                $0.isWorking = false
                $0.errorMessage = error.localizedDescription
            }
        }
    }

    func approve(_ id: MnemonicInboxRow.ID) async {
        guard let index = index(of: id),
              !rows[index].isWorking,
              let draft = rows[index].draft,
              let draftPrompt = rows[index].draftPrompt
        else { return }
        rows[index].isWorking = true
        rows[index].errorMessage = nil
        let item = rows[index].item

        do {
            try await client.approve(item, draftPrompt, draft)
            rows.removeAll { $0.id == id }
            approvedCount += 1
        } catch {
            update(id) {
                $0.isWorking = false
                $0.errorMessage = error.localizedDescription
            }
        }
    }

    func discard(_ id: MnemonicInboxRow.ID) async {
        guard let index = index(of: id), !rows[index].isWorking else { return }
        rows[index].isWorking = true
        rows[index].errorMessage = nil
        let item = rows[index].item

        do {
            try await client.discard(item)
            rows.removeAll { $0.id == id }
        } catch {
            update(id) {
                $0.isWorking = false
                $0.errorMessage = error.localizedDescription
            }
        }
    }

    private func index(of id: MnemonicInboxRow.ID) -> Int? {
        rows.firstIndex { $0.id == id }
    }

    /// Re-finds the row after an `await`: it may have moved or gone.
    private func update(_ id: MnemonicInboxRow.ID, _ change: (inout MnemonicInboxRow) -> Void) {
        guard let index = index(of: id) else { return }
        change(&rows[index])
    }
}
