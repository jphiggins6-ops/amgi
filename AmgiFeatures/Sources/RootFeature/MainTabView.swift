//
//  MainTabView.swift
//  RootFeature
//
//  Created by Vladimir Gusev on 27.03.2026.
//

import AppCore
import AnkiKit
import DecksFeature
import GraveyardFeature
import ReaderFeature
import SettingsFeature
import StatsFeature
import SwiftUI
import SyncFeature

/// Root tab bar. Pure layout: each tab wraps a feature view in a
/// `NavigationStack`. `refreshID` (bumped by the host after sync / import /
/// review) now only drives the tabs not yet on `CollectionStore` — Library
/// and Study reload via the store's generation instead. All side effects are
/// forwarded to the host via closures or `\.startSync` so this view owns no
/// I/O or sync state.
///
/// `refreshID` is *handed to* the two tabs that reload from it, not applied as
/// an `.id()`. As an `.id()` it discarded each tab's whole subtree — scroll
/// position, search text, selected deck, pushed navigation — to trigger a
/// reload their own `.task` already performs. Settings took the teardown and
/// got nothing for it: its root has no data load at all.
struct MainTabView: View {
    let refreshID: UUID
    let showReaderTab: Bool
    let onImport: () -> Void
    let onSelectStudyDeck: (DeckID) -> Void

    @Environment(\.startSync) private var startSync

    private enum MainTab: Hashable {
        case library, read, study, stats, graveyard
    }

    @State private var selection: MainTab = .library
    /// Settings lives behind the Library's More menu rather than in a tab.
    @State private var showSettings = false

    var body: some View {
        TabView(selection: $selection) {
            // 1. Library
            Tab("Library", systemImage: "rectangle.stack", value: MainTab.library) {
                NavigationStack {
                    DeckListView(
                        onSwitchProfile: { await switchProfile(to: $0) },
                        onSync: { startSync() },
                        onImport: onImport,
                        onOpenSettings: { showSettings = true }
                    )
                    .navigationDestination(isPresented: $showSettings) {
                        SettingsView(onSwitchProfile: { await switchProfile(to: $0) })
                    }
                }
            }
            // 2. Reader and 3. Study both live in ReaderFeature.
            if showReaderTab {
                Tab("Read", systemImage: "book", value: MainTab.read) {
                    NavigationStack {
                        ReaderLibraryView(refreshID: refreshID)
                    }
                }
            }
            Tab("Study", systemImage: "graduationcap", value: MainTab.study) {
                NavigationStack {
                    StudyLandingView(onSelectDeck: onSelectStudyDeck)
                }
            }
            // 4. Stats
            Tab("Stats", systemImage: "chart.bar", value: MainTab.stats) {
                NavigationStack {
                    StatsDashboardView(refreshID: refreshID)
                }
            }
            // 5. Graveyard — red- and orange-flagged cards, to fix or delete.
            Tab("Graveyard", systemImage: "flag.2.crossed", value: MainTab.graveyard) {
                NavigationStack {
                    GraveyardView()
                }
            }
        }
        .background {
            Button("Settings") {
                selection = .library
                showSettings = true
            }
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

}
