//
//  DeckGridCardView.swift
//  UI
//
//  Created by Vladimir Gusev on 18.09.2026.
//

#if !os(watchOS)
public import SwiftUI
import Theme

public enum DeckLayout: String, CaseIterable, Identifiable, Sendable {
    case list
    case grid

    public var id: String { rawValue }

    var label: String { self == .list ? "List view" : "Grid view" }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

public struct DeckGridCardView: View {
    let data: DeckRowViewData
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void

    @Environment(\.palette) private var palette

    public init(
        data: DeckRowViewData,
        isSelected: Bool = false,
        onTap: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping () -> Void
    ) {
        self.data = data
        self.isSelected = isSelected
        self.onTap = onTap
        self.onDelete = onDelete
        self.onRename = onRename
    }

    public var body: some View {
        // Not a Button with a context menu: the grid's cards all sit in one
        // list row, whose long-press menu was always the first card's, so
        // Delete took the top deck. The ⋯ menu is each card's own.
        AmgiCard(
            background: isSelected ? .solid(palette.accentSoft) : .surfaceElevated,
            shadow: palette.shadows.sm,
            cornerRadius: AmgiRadius.hero,
            contentInsets: EdgeInsets(
                top: AmgiSpacing.md, leading: AmgiSpacing.md,
                bottom: AmgiSpacing.md, trailing: AmgiSpacing.md
            )
        ) {
            VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                header
                HStack(alignment: .center, spacing: AmgiSpacing.xs) {
                    naming
                    moreMenu
                }
                Spacer(minLength: 0)
                CountSplitBar(
                    newCount: data.newCount,
                    learnCount: data.learnCount,
                    reviewCount: data.reviewCount
                )
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(data.name), \(accessibilityCounts)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onTap)
    }

    private var moreMenu: some View {
        Menu {
            Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
            // The list asks first (`onDelete`), naming this deck.
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Rename or delete \(data.name)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AmgiSpacing.sm) {
            DeckTile(name: data.name, isFiltered: data.isFiltered)
            Spacer(minLength: 0)
            if data.totalCount == 0 {
                Image(systemName: "checkmark")
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.cardStateReview)
            } else {
                Text("\(data.totalCount)")
                    .amgiFont(size: 22, weight: .bold, relativeTo: .title3)
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
                    .contentTransition(.numericText())
                    .animation(AmgiMotion.quick, value: data.totalCount)
            }
        }
    }

    private var naming: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xxs) {
            Text(data.name)
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(palette.textPrimary)
            Text(metaLine)
                .amgiFont(.micro)
                .foregroundStyle(palette.textSecondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaLine: String {
        if data.isFiltered { return "Filtered deck" }
        if data.totalCount == 0 { return "Up to date" }
        if data.subdeckCount > 0 {
            return "\(data.subdeckCount) subdeck\(data.subdeckCount == 1 ? "" : "s")"
        }
        return data.totalCount == 1 ? "card due" : "cards due"
    }

    private var accessibilityCounts: String {
        guard data.totalCount > 0 else { return "up to date" }
        var parts: [String] = []
        if data.newCount > 0 { parts.append("\(data.newCount) new") }
        if data.learnCount > 0 { parts.append("\(data.learnCount) learning") }
        if data.reviewCount > 0 { parts.append("\(data.reviewCount) to review") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Count split bar

private struct CountSplitBar: View {
    let newCount: Int
    let learnCount: Int
    let reviewCount: Int

    @Environment(\.palette) private var palette

    private static let gap: CGFloat = 2
    private static let height: CGFloat = 4

    var body: some View {
        let segments = segments
        if !segments.isEmpty {
            GeometryReader { geo in
                let available = geo.size.width - Self.gap * CGFloat(segments.count - 1)
                let total = CGFloat(segments.reduce(0) { $0 + $1.value })
                HStack(spacing: Self.gap) {
                    ForEach(segments, id: \.id) { segment in
                        Capsule()
                            .fill(segment.color)
                            .frame(width: max(Self.height, available * CGFloat(segment.value) / total))
                    }
                }
            }
            .frame(height: Self.height)
            .accessibilityHidden(true)
        }
    }

    private struct Segment {
        let id: String
        let value: Int
        let color: Color
    }

    private var segments: [Segment] {
        [
            Segment(id: "new", value: newCount, color: palette.cardStateNew),
            Segment(id: "learn", value: learnCount, color: palette.cardStateLearning),
            Segment(id: "review", value: reviewCount, color: palette.cardStateReview)
        ].filter { $0.value > 0 }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Grid cards") {
    LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 150), spacing: AmgiSpacing.md)],
        spacing: AmgiSpacing.md
    ) {
        DeckGridCardView(
            data: DeckRowViewData(
                id: 1, name: "한국어", fullName: "한국어",
                newCount: 20, learnCount: 93, reviewCount: 74,
                isFiltered: false, subdeckCount: 4
            ),
            onTap: {}, onDelete: {}, onRename: {}
        )
        DeckGridCardView(
            data: DeckRowViewData(
                id: 2, name: "Español", fullName: "Español",
                newCount: 0, learnCount: 0, reviewCount: 0,
                isFiltered: false, subdeckCount: 0
            ),
            onTap: {}, onDelete: {}, onRename: {}
        )
        DeckGridCardView(
            data: DeckRowViewData(
                id: 3, name: "Hardest cards", fullName: "Hardest cards",
                newCount: 0, learnCount: 0, reviewCount: 24,
                isFiltered: true, subdeckCount: 0
            ),
            onTap: {}, onDelete: {}, onRename: {}
        )
        DeckGridCardView(
            data: DeckRowViewData(
                id: 4, name: "ComputerScience", fullName: "ComputerScience",
                newCount: 20, learnCount: 35, reviewCount: 72,
                isFiltered: false, subdeckCount: 0
            ),
            isSelected: true,
            onTap: {}, onDelete: {}, onRename: {}
        )
    }
    .padding(AmgiSpacing.lg)
    .environment(\.palette, .vividLight)
}
#endif
#endif  // !os(watchOS)
