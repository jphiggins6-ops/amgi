//
//  FilteredDeckPresetEditorSheet.swift
//  DecksFeature
//

import SwiftUI
import AnkiKit
import AppCore

/// Add/edit form for one preset. Purely local — a preset is app state,
/// so there is no engine call here and nothing to fail; the search is
/// only validated when a deck is actually built.
struct FilteredDeckPresetEditorSheet: View {
    let title: String
    let onSave: (FilteredDeckPreset) -> Void

    @State private var draft: FilteredDeckPreset
    @Environment(\.dismiss) private var dismiss

    init(
        preset: FilteredDeckPreset,
        title: String,
        onSave: @escaping (FilteredDeckPreset) -> Void
    ) {
        self.title = title
        self.onSave = onSave
        _draft = State(initialValue: preset)
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedQuery: String {
        draft.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Deck name", text: $draft.name)
                        .autocorrectionDisabled()
                } footer: {
                    Text("The filtered deck is named after the preset. Running it again refreshes that deck instead of making another one.")
                }

                Section {
                    TextField("is:due tag:leech", text: $draft.searchQuery)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Search")
                } footer: {
                    Text("Anki search syntax — e.g. `added:1 -is:suspended`, `prop:ivl<7 is:review`, `deck:Korean is:due`.")
                }

                Section {
                    Stepper(value: $draft.limit, in: 1...9999, step: 10) {
                        LabeledContent("Card limit", value: "\(draft.limit)")
                    }
                    Picker("Gather order", selection: $draft.order) {
                        ForEach(FilteredDeckOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                } footer: {
                    Text("At most this many cards are gathered, picked in this order.")
                }

                Section {
                    Toggle("Reschedule cards based on my answers", isOn: $draft.reschedule)
                } footer: {
                    Text(draft.reschedule
                         ? "Answers count towards the cards' real scheduling."
                         : "Preview only — answers are discarded when the deck is emptied.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = draft
                        saved.name = trimmedName
                        saved.searchQuery = trimmedQuery
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty || trimmedQuery.isEmpty)
                }
            }
        }
    }
}

extension FilteredDeckOrder {
    /// Mirrors upstream Anki's `FilteredDeckOrderLabels` wording so the
    /// picker reads the same as the desktop dialog. Not fetched over the
    /// RPC: that returns the backend's localized strings, and the rest of
    /// this screen is untranslated English.
    var label: String {
        switch self {
        case .oldestReviewedFirst: return "Oldest seen first"
        case .random: return "Random"
        case .intervalsAscending: return "Increasing intervals"
        case .intervalsDescending: return "Decreasing intervals"
        case .lapses: return "Most lapses"
        case .added: return "Order added"
        case .due: return "Order due"
        case .reverseAdded: return "Latest added first"
        case .retrievabilityAscending: return "Ascending retrievability"
        case .retrievabilityDescending: return "Descending retrievability"
        case .relativeOverdueness: return "Relative overdueness"
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Edit preset") {
    FilteredDeckPresetEditorSheet(
        preset: FilteredDeckPreset(
            name: "Leeches",
            searchQuery: "is:due tag:leech",
            limit: 50
        ),
        title: "Edit Preset",
        onSave: { _ in }
    )
}
#endif
