//
//  HandsFreeBanner.swift
//  ReviewFeature
//

#if canImport(UIKit)
import SwiftUI
import Theme

/// Hands-free's switch at the top of the review screen, in place of the
/// banner that used to sit under the progress bar. A tap turns it on or
/// off, and its colour says which: green while it runs, pulsing while it
/// listens, orange while the AI voice isn't coming through and the
/// iPhone's voice reads instead. A long press shows what it's doing, what
/// it heard last, and what to say. Why it stopped by itself, when it did,
/// is an alert on the review screen.
struct HandsFreeButton: View {
    let controller: HandsFreeController
    let onToggle: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Menu {
            if controller.isOn {
                Section {
                    Text(verbatim: status)
                    if let heard = controller.lastHeard {
                        Text(verbatim: "Heard “\(heard)”")
                    }
                    if let voiceProblem = controller.voiceProblem {
                        Text(verbatim: "The iPhone voice is reading: \(voiceProblem)")
                    }
                }
            }
            Section("Say") {
                Text(verbatim: "“Show” to turn the card over")
                Text(verbatim: "“Again”, “hard”, “good” or “easy” to rate it")
                Text(verbatim: "“Repeat”, “undo” or “stop”")
                Text(verbatim: "“Bury”, “red flag” or “orange flag”")
            }
            Section {
                Button(action: onToggle) {
                    Label(toggleTitle, systemImage: controller.isOn ? "stop.circle" : "headphones")
                }
            }
        } label: {
            Image(systemName: controller.isOn ? "headphones.circle.fill" : "headphones")
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: isListening)
        } primaryAction: {
            onToggle()
        }
        .accessibilityLabel(toggleTitle)
        .accessibilityValue(controller.isOn ? status : "Off")
    }

    private var tint: Color {
        guard controller.isOn else { return palette.accent }
        return controller.voiceProblem == nil ? palette.positive : palette.warning
    }

    private var isListening: Bool {
        controller.phase == .waitingToShow || controller.phase == .waitingForRating
    }

    private var toggleTitle: String {
        controller.isOn ? "Stop Hands-Free" : "Start Hands-Free"
    }

    /// What it's doing, in a few words.
    private var status: String {
        switch controller.phase {
        case .off: "Off"
        case .starting: "Starting…"
        case .readingQuestion: "Reading the question…"
        case .waitingToShow: "Listening: say “show”, or rate it"
        case .readingAnswer: "Reading the answer…"
        case .waitingForRating: "Listening: say again, hard, good or easy"
        case .finishing: "That’s the last card"
        }
    }
}
#endif
