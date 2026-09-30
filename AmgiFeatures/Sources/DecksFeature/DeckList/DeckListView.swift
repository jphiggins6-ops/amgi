//
//  DeckListView.swift
//  DecksFeature
//
//  Created by Vladimir Gusev on 14.05.2026.
//

package import SwiftUI
package import AppCore
import AppShared
import UI
import Theme
import AnkiKit
import AnkiClients
import Dependencies
import Sharing
import BrowseFeature
import ReviewFeature

package struct DeckListView: View {
    private let onSwitchProfile: (AmgiAccount) async -> Void
    private let onSync: () -> Void
    private let onImport: () -> Void
    @Dependency(\.collectionStore) private var store
    @State private var model: DeckListModel
    @State private var showCreateSheet = false
    @State private var showBrowse = false
    @State private var showFilteredDecks = false
    @State private var showMnemonics = false
    @State private var studyNowDeckId: DeckID?
    @State private var isBuildingStudyNow = false
    @State private var studyNowError: String?
    /// Emptying Study Now after a session; a new session waits for it, or
    /// the late empty could clear the deck the new session just built.
    @State private var finishingStudyNow: Task<Void, Never>?
    @State private var renameTarget: DeckRowViewData?
    @State private var pendingDeck: DeckInfo?
    @State private var accounts = AccountStore.shared
    @Shared(.appStorage(AppearancePreferences.Keys.showProfileInToolbar))
    private var showProfileInToolbar = true

    package init(
        onSwitchProfile: @escaping (AmgiAccount) async -> Void,
        onSync: @escaping () -> Void,
        onImport: @escaping () -> Void
    ) {
        self.onSwitchProfile = onSwitchProfile
        self.onSync = onSync
        self.onImport = onImport
        _model = State(initialValue: DeckListModel())
    }

    /// Preview / test seam — internal so the model stays module-private.
    init(
        model: DeckListModel,
        onSwitchProfile: @escaping (AmgiAccount) async -> Void = { _ in },
        onSync: @escaping () -> Void = {},
        onImport: @escaping () -> Void = {}
    ) {
        self.onSwitchProfile = onSwitchProfile
        self.onSync = onSync
        self.onImport = onImport
        _model = State(initialValue: model)
    }

    package var body: some View {
        LibraryListContent(
            state: model.state,
            selectedDeckID: pendingDeck?.id.rawValue,
            onRefresh: { await model.load() },
            onStartReviews: { Task { await startStudyNow(.reviews) } },
            onStartNew: { Task { await startStudyNow(.newCards) } },
            onTapDeck: { row in pendingDeck = row.asDeckInfo },
            onDeleteDeck: { rawID in await model.delete(DeckID(rawID)) },
            onRenameDeck: { row in renameTarget = row },
            onCreateDeck: { showCreateSheet = true }
        )
        .equatable()
        .navigationTitle("Library")
        .navigationDestination(item: $pendingDeck) { deck in
            DeckDetailView(deck: deck)
        }
        #if canImport(UIKit)
        .navigationDestination(isPresented: $showBrowse) {
            BrowseView()
        }
        #endif
        .navigationDestination(isPresented: $showFilteredDecks) {
            FilteredDeckPresetsView()
        }
        .navigationDestination(isPresented: $showMnemonics) {
            MnemonicInboxView()
        }
        .toolbar { toolbarContent }
        .fullScreenCover(item: $studyNowDeckId) { deckId in
            ReviewView(deckId: deckId, countsNewCardsAgainstHomeDecks: true) {
                studyNowDeckId = nil
                finishingStudyNow = Task { await model.finishStudyNow(deckId) }
            }
        }
        .alert(
            "Nothing to study",
            isPresented: Binding(get: { studyNowError != nil }, set: { if !$0 { studyNowError = nil } }),
            presenting: studyNowError
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateDeckSheet {
                showCreateSheet = false
            }
        }
        .sheet(item: $renameTarget) { row in
            RenameDeckSheet(deckId: DeckID(row.id), currentName: row.fullName) {
                renameTarget = nil
            }
        }
        .task(id: store.generation) { await model.load() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if showsProfilePicker {
            ToolbarItem(placement: .navigation) {
                ProfilePickerMenu(onSwitch: onSwitchProfile)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Sync", systemImage: "arrow.triangle.2.circlepath", action: onSync)
                .keyboardShortcut("r", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Button("New Deck", systemImage: "plus") {
                showCreateSheet = true
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                #if canImport(UIKit)
                Button {
                    showBrowse = true
                } label: {
                    Label("Browse Notes", systemImage: "doc.text")
                }
                #endif
                Button {
                    showFilteredDecks = true
                } label: {
                    Label("Filtered Decks…", systemImage: "line.3.horizontal.decrease.circle")
                }
                Button {
                    showMnemonics = true
                } label: {
                    Label("Mnemonics…", systemImage: "sparkles")
                }
                Button(action: onImport) {
                    Label("Import Deck…", systemImage: "square.and.arrow.down")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private func startStudyNow(_ kind: DeckListModel.StudyNowKind) async {
        guard !isBuildingStudyNow else { return }
        isBuildingStudyNow = true
        defer { isBuildingStudyNow = false }
        await finishingStudyNow?.value
        do {
            studyNowDeckId = try await model.buildStudyNowDeck(kind)
        } catch {
            // Nothing left to gather: the engine refuses to build a filtered
            // deck from an empty search, and New throws before asking it.
            studyNowError = error.localizedDescription
        }
    }

    private var showsProfilePicker: Bool {
        showProfileInToolbar && accounts.accounts.count > 1
    }
}
