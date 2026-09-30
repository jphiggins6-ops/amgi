//
//  MnemonicInboxView.swift
//  DecksFeature
//

package import SwiftUI
import MnemonicCore
import Theme
#if canImport(UIKit)
import UIKit
#endif

/// Every idea saved with ✨, one card each: see what it's for, edit the
/// description, make a draft, then approve it onto the card or discard it.
package struct MnemonicInboxView: View {
    @State private var model = MnemonicInboxModel()
    @State private var discardTarget: MnemonicInboxRow.ID?

    package init() {}

    /// Preview / test seam — internal so the model stays module-private.
    init(model: MnemonicInboxModel) {
        _model = State(initialValue: model)
    }

    package var body: some View {
        content
            .navigationTitle("Mnemonics")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.load() }
            .sensoryFeedback(.success, trigger: model.approvedCount)
            .confirmationDialog(
                "Discard this idea?",
                isPresented: Binding(get: { discardTarget != nil }, set: { if !$0 { discardTarget = nil } }),
                titleVisibility: .visible,
                presenting: discardTarget
            ) { id in
                Button("Discard", role: .destructive) {
                    Task { await model.discard(id) }
                }
            } message: { _ in
                Text("It's removed from the card. This can't be undone.")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load mnemonics", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
        case .loaded where model.rows.isEmpty:
            ContentUnavailableView {
                Label("No ideas waiting", systemImage: "sparkles")
            } description: {
                Text("While reviewing, tap ✨ to save an idea for a picture. It shows up here.")
            }
        case .loaded:
            List {
                ForEach(model.rows) { row in
                    MnemonicInboxRowView(
                        row: row,
                        prompt: Binding(
                            get: { row.prompt },
                            set: { model.setPrompt($0, for: row.id) }
                        ),
                        onGenerate: { Task { await model.generate(row.id) } },
                        onApprove: { Task { await model.approve(row.id) } },
                        onDiscard: { discardTarget = row.id }
                    )
                }
            }
            .refreshable { await model.load() }
        }
    }
}

// MARK: - Row

private struct MnemonicInboxRowView: View {
    let row: MnemonicInboxRow
    @Binding var prompt: String
    let onGenerate: () -> Void
    let onApprove: () -> Void
    let onDiscard: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.item.cardSummary.isEmpty ? "(empty card)" : row.item.cardSummary)
                        .amgiFont(size: 15, weight: .semibold)
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(3)
                    Text("Picture goes in: \(row.item.fieldName)")
                        .amgiFont(size: 12, weight: .regular)
                        .foregroundStyle(palette.textSecondary)
                }

                TextField("Describe the picture", text: $prompt, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
                    .disabled(row.isWorking)

                preview

                if row.draftIsStale {
                    Text("The picture shows the previous description — tap Try Again to redraw it.")
                        .amgiFont(size: 12, weight: .regular)
                        .foregroundStyle(palette.textSecondary)
                }

                if let errorMessage = row.errorMessage {
                    Text(errorMessage)
                        .amgiFont(size: 13, weight: .regular)
                        .foregroundStyle(palette.danger)
                }

                // Explicit button styles on every button: without them, a
                // tap anywhere in a List row fires all of the row's buttons.
                HStack(spacing: 12) {
                    Button(generateTitle, systemImage: "wand.and.stars", action: onGenerate)
                        .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                    Button("Discard", systemImage: "trash", role: .destructive, action: onDiscard)
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                    Button("Approve", systemImage: "checkmark", action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .disabled(row.draft == nil)
                }
                .disabled(row.isWorking)
            }
            .padding(.vertical, 6)
        }
    }

    /// A plain `String`, so `Button` takes its string overload rather than
    /// having to choose between that and `LocalizedStringKey` for a ternary.
    private var generateTitle: String {
        row.draft == nil ? "Generate" : "Try Again"
    }

    @ViewBuilder
    private var preview: some View {
        if row.isWorking {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.surfaceElevated)
                .frame(height: 200)
                .overlay { ProgressView() }
        } else if let draft = row.draft, let image = decoded(draft) {
            image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func decoded(_ draft: MnemonicImage) -> Image? {
        #if canImport(UIKit)
        guard let uiImage = UIImage(data: draft.data) else { return nil }
        return Image(uiImage: uiImage)
        #else
        return nil
        #endif
    }
}
