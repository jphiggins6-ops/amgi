//
//  NativeCardView.swift
//  ReviewFeature
//
//  Created by Vladimir Gusev on 20.07.2026.
//

import SwiftUI
import AppCore
import UI
import Theme
import AmgiCardWeb

/// Native SwiftUI renderer for allowlist-simple cards (R11). Renders the
/// side's parsed blocks on a radius-24 `AmgiCard` surface: the first text
/// block is the serif headword (large on the front, reduced on the back —
/// Anki back HTML already contains `{{FrontSide}}` plus an `<hr>` divider),
/// remaining text blocks are body copy, `<hr>` becomes a hairline.
struct NativeCardView: View {
    let content: NativeCardContent
    let isAnswerSide: Bool
    let mediaFolder: URL?
    var onGesture: ((ReviewGesture) -> Void)? = nil

    @Environment(\.palette) private var palette
    @State private var size: CGSize = .zero
    @State private var scrollOffset: CGFloat = 0
    @State private var dragStartOffset: CGFloat? = nil

    @ScaledMetric(relativeTo: .largeTitle) private var headwordFront: CGFloat = 48
    @ScaledMetric(relativeTo: .title) private var headwordBack: CGFloat = 34
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 20

    var body: some View {
        ScrollView {
            AmgiCard(
                background: .surface,
                cornerRadius: AmgiRadius.card,
                contentInsets: EdgeInsets(top: 40, leading: 24, bottom: 40, trailing: 24)
            ) {
                VStack(spacing: AmgiSpacing.lg) {
                    ForEach(Array(content.blocks.enumerated()), id: \.offset) { index, block in
                        blockView(block, isFirst: index == firstTextIndex)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        // Content that fits must not bounce, or every vertical swipe would
        // scroll it and be discarded as a scroll.
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, offset in
            scrollOffset = offset
        }
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            guard let onGesture, size.width > 0, size.height > 0 else { return }
            onGesture(.tap(x: location.x / size.width, y: location.y / size.height))
        }
        .simultaneousGesture(swipe)
    }

    /// A quick, mostly straight drag. A vertical one that scrolled the card
    /// was a scroll, not a swipe.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { _ in
                if dragStartOffset == nil { dragStartOffset = scrollOffset }
            }
            .onEnded { value in
                let start = dragStartOffset ?? scrollOffset
                dragStartOffset = nil
                guard let onGesture else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) >= 60, abs(dx) >= 2 * abs(dy) {
                    onGesture(dx < 0 ? .swipeLeft : .swipeRight)
                } else if abs(dy) >= 60, abs(dy) >= 2 * abs(dx), abs(scrollOffset - start) <= 12 {
                    onGesture(dy < 0 ? .swipeUp : .swipeDown)
                }
            }
    }

    private var firstTextIndex: Int? {
        content.blocks.firstIndex {
            if case .text = $0 { return true }
            return false
        }
    }

    @ViewBuilder
    private func blockView(_ block: NativeCardContent.Block, isFirst: Bool) -> some View {
        switch block {
        case .text(let attributed):
            // One `Text` with ternary modifier arguments rather than an
            // if/else over two `Text`s: the branches differed only in font and
            // scale factor, and `_ConditionalContent` would give the same
            // block two structural identities.
            Text(attributed)
                .font(.system(
                    size: isFirst ? (isAnswerSide ? headwordBack : headwordFront) : bodySize,
                    weight: isFirst ? .semibold : .regular,
                    design: .serif
                ))
                .minimumScaleFactor(isFirst ? 0.5 : 1)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.textPrimary)
        case .image(let filename):
            // Decoded and downsampled off the main thread — a full-resolution
            // decode here lands squarely in the answer-reveal frame.
            DownsampledImage(
                url: mediaFolder?.appendingPathComponent(filename),
                maxPixelSize: AmgiImagePixelSize.card
            ) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
            } placeholder: {
                EmptyView()
            }
        case .divider:
            Rectangle()
                .fill(palette.separator)
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
    }
}

#if DEBUG
#Preview("Front") {
    NativeCardView(
        content: .parse(html: "猫"),
        isAnswerSide: false,
        mediaFolder: nil
    )
}

#Preview("Back") {
    NativeCardView(
        content: .parse(html: "猫<hr>cat<br><i>The cat sat on the mat.</i>"),
        isAnswerSide: true,
        mediaFolder: nil
    )
}
#endif
