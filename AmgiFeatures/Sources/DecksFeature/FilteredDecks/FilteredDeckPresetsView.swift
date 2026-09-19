//
//  FilteredDeckPresetsView.swift
//  DecksFeature
//

package import SwiftUI
import AppCore
import Theme

/// Saved filtered-deck recipes, and a one-tap build for any selection of
/// them. The engine already exposes rebuild/empty for a filtered deck
/// that exists (`DeckCustomStudyCard`); this is the missing half —
/// creating them without leaving the app.
package struct FilteredDeckPresetsView: View {
    @State private var model = FilteredDeckPresetsModel()
    @State private var editorTarget: FilteredDeckPreset?
    @State private var editorTitle = "Edit Preset"
    @State private var isAddingNew = false

    package init() {}

    /// Preview / test seam — internal so the model stays module-private.
    init(model: FilteredDeckPresetsModel) {
        _model = State(initialValue: model)
    }

    package var body: some View {
        content
            .navigationTitle("Filtered Decks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(item: $editorTarget) { preset in
                FilteredDeckPresetEditorSheet(preset: preset, title: editorTitle) { saved in
                    save(saved)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.store.presets.isEmpty {
            ContentUnavailableView {
                Label("No presets", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Save a search here and build a filtered deck from it in one tap.")
            } actions: {
                Button("New Preset") { startAdding() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                presetsSection
                resultsSection
            }
            .safeAreaInset(edge: .bottom) { quickCreateBar }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !model.store.presets.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("New Preset", systemImage: "plus") { startAdding() }
        }
    }
}

// MARK: - Sections

private extension FilteredDeckPresetsView {
    var presetsSection: some View {
        Section {
            ForEach(model.store.presets) { preset in
                FilteredDeckPresetRow(
                    preset: preset,
                    isSelected: model.selection.contains(preset.id),
                    onTap: { model.toggle(preset) },
                    onEdit: { startEditing(preset) }
                )
            }
            // Resolve offsets to presets before deleting any of them —
            // deleting by index in a loop shifts the ones behind it.
            .onDelete { offsets in
                for preset in offsets.map({ model.store.presets[$0] }) {
                    model.forget(id: preset.id)
                }
            }
            .onMove { source, destination in
                var reordered = model.store.presets
                reordered.move(fromOffsets: source, toOffset: destination)
                model.store.reorder(reordered)
            }
        } header: {
            Text("Presets")
        } footer: {
            Text("Tap to include a preset in Quick Create. Swipe or use Edit to reorder and delete.")
        }
    }

    @ViewBuilder
    var resultsSection: some View {
        if !model.results.isEmpty {
            Section {
                ForEach(model.results) { result in
                    FilteredDeckResultRow(result: result)
                }
            } header: {
                Text("Last run")
            }
        }
    }

    var quickCreateBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                Task { await model.build() }
            } label: {
                HStack(spacing: 8) {
                    if model.isBuilding {
                        ProgressView()
                    } else {
                        Image(systemName: "bolt.fill")
                    }
                    Text(quickCreateTitle)
                        .amgiFont(size: 16, weight: .semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selection.isEmpty || model.isBuilding)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    var quickCreateTitle: String {
        let count = model.selectedPresets.count
        switch count {
        case 0: return "Quick Create"
        case 1: return "Quick Create 1 Deck"
        default: return "Quick Create \(count) Decks"
        }
    }
}

// MARK: - Actions

private extension FilteredDeckPresetsView {
    func startAdding() {
        isAddingNew = true
        editorTitle = "New Preset"
        editorTarget = FilteredDeckPreset(name: "", searchQuery: "")
    }

    func startEditing(_ preset: FilteredDeckPreset) {
        isAddingNew = false
        editorTitle = "Edit Preset"
        editorTarget = preset
    }

    /// A new preset is selected on save, so the button it was created
    /// for counts it immediately.
    func save(_ preset: FilteredDeckPreset) {
        if isAddingNew {
            model.store.add(preset)
            model.selection.insert(preset.id)
        } else {
            model.store.update(preset)
        }
        editorTarget = nil
    }
}

// MARK: - Rows

private struct FilteredDeckPresetRow: View {
    let preset: FilteredDeckPreset
    let isSelected: Bool
    let onTap: () -> Void
    let onEdit: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? palette.accent : palette.border)
                .font(.system(size: 20))

            VStack(alignment: .leading, spacing: 3) {
                Text(preset.name)
                    .amgiFont(size: 16, weight: .semibold)
                Text(preset.searchQuery)
                    .amgiFont(size: 13, weight: .regular)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                Text("\(preset.limit) cards · \(preset.order.label)\(preset.reschedule ? "" : " · preview")")
                    .amgiFont(size: 12, weight: .regular)
                    .foregroundStyle(palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .swipeActions(edge: .leading) {
            Button("Edit", systemImage: "pencil", action: onEdit)
                .tint(palette.accent)
        }
    }
}

private struct FilteredDeckResultRow: View {
    let result: FilteredDeckBuildResult

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .amgiFont(size: 15, weight: .semibold)
                Text(detail)
                    .amgiFont(size: 13, weight: .regular)
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }

    private var icon: String {
        switch result.outcome {
        case .built: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var tone: Color {
        switch result.outcome {
        case .built: return palette.accent
        case .failed: return palette.danger
        }
    }

    private var detail: String {
        switch result.outcome {
        case .built(let cardCount):
            return cardCount == 1 ? "1 card gathered" : "\(cardCount) cards gathered"
        case .failed(let message):
            return message
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Presets") {
    NavigationStack {
        FilteredDeckPresetsView()
    }
    .environment(\.palette, .vividLight)
}
#endif
