//
//  HandsFreeBanner.swift
//  ReviewFeature
//

#if canImport(UIKit)
import SwiftUI
import Theme

/// The strip under the progress bar while hands-free is on: what it's
/// doing, what to say, and a button to stop. It stays to say why, if
/// hands-free stopped by itself.
struct HandsFreeBanner: View {
    let controller: HandsFreeController

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: AmgiSpacing.sm) {
            Image(systemName: controller.problem == nil ? "headphones" : "exclamationmark.triangle.fill")
                .foregroundStyle(controller.problem == nil ? palette.accent : palette.warning)
                .symbolEffect(.pulse, isActive: isListening)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .amgiFont(.captionBold)
                    .foregroundStyle(palette.textPrimary)
                Text(verbatim: detail)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(3)
                if controller.problem == nil, let voiceProblem = controller.voiceProblem {
                    Text(verbatim: "The AI voice didn’t come through, so the iPhone voice is reading. \(voiceProblem)")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.warning)
                        .lineLimit(3)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.large)
                    .foregroundStyle(palette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(closeLabel)
        }
        .padding(.horizontal, AmgiSpacing.md)
        .padding(.vertical, AmgiSpacing.sm)
        .background(palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
        .padding(.horizontal)
        .padding(.top, AmgiSpacing.xs)
    }

    private var isListening: Bool {
        controller.phase == .waitingToShow || controller.phase == .waitingForRating
    }

    private var title: String {
        if controller.problem != nil { return "Hands-free stopped" }
        switch controller.phase {
        case .off: return "Hands-free"
        case .starting: return "Starting hands-free…"
        case .readingQuestion: return "Reading the question…"
        case .waitingToShow, .waitingForRating: return "Listening…"
        case .readingAnswer: return "Reading the answer…"
        case .finishing: return "That's the last card"
        }
    }

    private var detail: String {
        if let problem = controller.problem { return problem }
        let heard = controller.lastHeard.map { "Heard “\($0)”. " } ?? ""
        switch controller.phase {
        case .readingQuestion, .waitingToShow:
            return heard + "Say “show”, or rate it now: again, hard, good, easy."
        case .readingAnswer, .waitingForRating:
            return heard + "Say again, hard, good or easy. “Repeat”, “undo” and “stop” work too."
        case .off, .starting, .finishing:
            return heard + "Each card is read aloud, and you answer by voice."
        }
    }

    private var closeLabel: String {
        controller.isOn ? "Stop hands-free" : "Dismiss"
    }

    private func close() {
        if controller.isOn {
            controller.stop()
        } else {
            controller.dismissProblem()
        }
    }
}
#endif
