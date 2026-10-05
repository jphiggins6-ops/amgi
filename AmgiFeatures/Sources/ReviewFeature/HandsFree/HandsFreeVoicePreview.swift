//
//  HandsFreeVoicePreview.swift
//  ReviewFeature
//

#if canImport(UIKit)
import AVFoundation
import Foundation
import AppCore
import MnemonicCore

/// Settings' samples of the hands-free voices, so one can be picked by ear.
@MainActor
public final class HandsFreeVoicePreview {
    private let speaker = CardSpeaker()
    private let recorder = AIVoiceRecorder()
    /// Samples playing, so the audio is let go only after the last.
    private var playing = 0

    static let sample = "The drug of choice for absence seizures is ethosuximide. Say “show”, and I’ll read the answer."

    public init() {}

    /// The sample in an iPhone voice: `identifier`, or the best one
    /// installed when nil.
    public func playIPhoneVoice(_ identifier: String?) async {
        begin()
        speaker.preferredVoice = identifier
        await speaker.speak(Self.sample)
        end()
    }

    /// The sample in one of OpenAI's voices, recorded the first time
    /// (a fraction of a cent) and kept. Nil once it has played, otherwise
    /// why it couldn't.
    public func playAIVoice(_ voice: String) async -> String? {
        guard recorder.hasKey else { return CardExplanationError.noKey.localizedDescription }
        guard let recording = await recorder.recording(
            of: Self.sample,
            voice: voice,
            make: true,
            waitingAtMost: .seconds(30)
        ) else {
            return recorder.problem ?? "OpenAI took too long to answer. Try again in a moment."
        }
        begin()
        let played = await speaker.play(recording)
        end()
        if !played {
            CardVoiceRecordings.discard(recording)
            return "That recording couldn't be played. Try again to make a new one."
        }
        return nil
    }

    public func stop() {
        speaker.stop()
    }

    /// Out loud even with the ringer off: the sample was asked for.
    private func begin() {
        playing += 1
        speaker.speed = ReviewPreferences.handsFreeSpeed
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func end() {
        playing -= 1
        if playing == 0 {
            ReviewAudioSession.release()
        }
    }
}
#endif
