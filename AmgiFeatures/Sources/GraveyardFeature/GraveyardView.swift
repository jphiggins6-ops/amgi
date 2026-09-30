//
//  GraveyardView.swift
//  GraveyardFeature
//

package import SwiftUI
import AppCore
import AppShared
import Dependencies

/// Every card flagged red or orange, to be fixed, illustrated, or deleted.
/// Flagged cards are left out of the Library's Reviews button, so a card
/// stays here, out of the daily review, until it is dealt with.
package struct GraveyardView: View {
    @State private var model = GraveyardModel()
    @State private var showSettings = false
    @Dependency(\.collectionStore) private var store

    package init() {}

    package var body: some View {
        content
            .navigationTitle("Graveyard")
            .task(id: store.generation) { await model.load() }
            .refreshable { await model.load() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("AI Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) {
                GraveyardSettingsSheet()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Flagged Cards", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded(let items) where items.isEmpty:
            ContentUnavailableView {
                Label("Nothing Here", systemImage: "flag.2.crossed")
            } description: {
                Text("Flag a card red or orange while reviewing and it lands here, out of your daily reviews, until you fix or delete it.")
            }
        case .loaded(let items):
            list(items)
        }
    }

    private func list(_ items: [GraveyardItem]) -> some View {
        List {
            ForEach([UInt32(1), 2], id: \.self) { flag in
                let group = items.filter { $0.flag == flag }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { item in
                            NavigationLink {
                                GraveyardCardView(item: item) {
                                    Task { await model.load() }
                                }
                            } label: {
                                GraveyardRow(item: item)
                            }
                        }
                    } header: {
                        Text("\(CardFlag.name(flag)) — \(group.count)")
                    }
                }
            }
        }
    }
}

private struct GraveyardRow: View {
    let item: GraveyardItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "flag.fill")
                .foregroundStyle(CardFlag.color(item.flag))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.front.isEmpty ? "(empty card)" : item.front)
                    .lineLimit(2)
                if !item.deckName.isEmpty {
                    Text(item.deckName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(CardFlag.name(item.flag)) flag. \(item.front). \(item.deckName)")
    }
}
