//
//  HandsFreeAudio.swift
//  ReviewFeature
//
//  The speaking, listening and audio-session plumbing for hands-free mode.
//  Every callback the system makes on its own threads is built in a
//  nonisolated function: a closure written inside main-actor code is
//  main-actor isolated, and Swift 6 traps when one runs anywhere else.
//

#if canImport(UIKit)
import AVFoundation
import Foundation
import Speech
import AppCore
import ReviewCore

// MARK: - Speaking

/// Reads text aloud, each run of a writing system in a voice for it, or
/// plays a recording of it in the AI voice, and returns once it has been
/// read or reading was stopped.
@MainActor
final class CardSpeaker {
    var speed: HandsFreeSpeed = .normal
    /// The iPhone voice picked in Settings, for text in its language; the
    /// best one installed when nil.
    var preferredVoice: String? {
        didSet { voices = [:] }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = SpeechDelegate()
    private var player: AVAudioPlayer?
    private let playerDelegate = PlayerDelegate()
    private var continuation: CheckedContinuation<Void, Never>?
    /// What the current `speak` queued, so a late callback for something
    /// stopped earlier can't end the next one.
    private var queued: Set<ObjectIdentifier> = []
    private var last: ObjectIdentifier?
    /// The voice for each language, chosen once.
    private var voices: [String: AVSpeechSynthesisVoice] = [:]

    init() {
        synthesizer.delegate = delegate
        delegate.onEnd = Self.forwarding(to: self)
        playerDelegate.onEnd = Self.forwardingPlayback(to: self)
    }

    func speak(_ text: String) async {
        stop()
        let segments = SpokenCardText.segments(text)
        guard !segments.isEmpty else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                for segment in segments {
                    let utterance = AVSpeechUtterance(string: segment.text)
                    utterance.voice = voice(for: segment.script)
                    utterance.rate = Self.rate(for: speed)
                    utterance.postUtteranceDelay = 0.05
                    queued.insert(ObjectIdentifier(utterance))
                    last = ObjectIdentifier(utterance)
                    synthesizer.speak(utterance)
                }
            }
        } onCancel: {
            Self.stopSoon(self)
        }
    }

    /// Plays a recording to the end, or until it's stopped. False when it
    /// can't be played, so the text can be read out instead.
    func play(_ recording: URL) async -> Bool {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: recording) else { return false }
        player.enableRate = true
        player.rate = Self.playbackRate(for: speed)
        player.delegate = playerDelegate
        self.player = player
        var playable = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                if !player.play() {
                    playable = false
                    stop()
                }
            }
        } onCancel: {
            Self.stopSoon(self)
        }
        return playable
    }

    /// Stops at once and lets a waiting `speak` or `play` return.
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        player?.stop()
        player = nil
        finish()
    }

    fileprivate func ended(_ utterance: ObjectIdentifier, cancelled: Bool) {
        guard queued.contains(utterance) else { return }
        if cancelled || utterance == last { finish() }
    }

    fileprivate func playbackEnded(_ finished: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == finished else { return }
        self.player = nil
        finish()
    }

    private func finish() {
        queued = []
        last = nil
        continuation?.resume()
        continuation = nil
    }

    /// The voice for `script`: the one picked in Settings when it speaks
    /// that language, otherwise the best one installed for it.
    private func voice(for script: SpokenCardText.Script) -> AVSpeechSynthesisVoice? {
        let language = Self.language(for: script)
        if let remembered = voices[language] { return remembered }
        let picked = preferredVoice
            .flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            .flatMap { candidate in
                HandsFreeVoices.languageCode(of: candidate.language) == HandsFreeVoices.languageCode(of: language)
                    ? candidate : nil
            }
        let chosen = picked ?? HandsFreeVoices.best(for: language) ?? AVSpeechSynthesisVoice(language: language)
        voices[language] = chosen
        return chosen
    }

    static func language(for script: SpokenCardText.Script) -> String {
        switch script {
        case .hangul: "ko-KR"
        case .japanese: "ja-JP"
        case .chinese: "zh-CN"
        case .other: AVSpeechSynthesisVoice.currentLanguageCode()
        }
    }

    static func rate(for speed: HandsFreeSpeed) -> Float {
        let normal = AVSpeechUtteranceDefaultSpeechRate
        switch speed {
        case .slow: return normal * 0.85
        case .normal: return normal
        case .fast: return min(normal * 1.15, AVSpeechUtteranceMaximumSpeechRate)
        }
    }

    /// A recording's speed: it's made at the AI voice's own pace.
    static func playbackRate(for speed: HandsFreeSpeed) -> Float {
        switch speed {
        case .slow: 0.85
        case .normal: 1
        case .fast: 1.2
        }
    }

    nonisolated private static func forwarding(to speaker: CardSpeaker) -> @Sendable (ObjectIdentifier, Bool) -> Void {
        { [weak speaker] utterance, cancelled in
            guard let speaker else { return }
            Task { @MainActor in speaker.ended(utterance, cancelled: cancelled) }
        }
    }

    nonisolated private static func forwardingPlayback(to speaker: CardSpeaker) -> @Sendable (ObjectIdentifier) -> Void {
        { [weak speaker] player in
            guard let speaker else { return }
            Task { @MainActor in speaker.playbackEnded(player) }
        }
    }

    nonisolated private static func stopSoon(_ speaker: CardSpeaker) {
        Task { @MainActor in speaker.stop() }
    }
}

/// AVSpeechSynthesizer's delegate, kept off the main actor: the
/// synthesizer calls it on a queue of its own choosing.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onEnd: (@Sendable (ObjectIdentifier, Bool) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onEnd?(ObjectIdentifier(utterance), false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onEnd?(ObjectIdentifier(utterance), true)
    }
}

/// AVAudioPlayer's delegate, kept off the main actor like `SpeechDelegate`.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onEnd: (@Sendable (ObjectIdentifier) -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onEnd?(ObjectIdentifier(player))
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        onEnd?(ObjectIdentifier(player))
    }
}

// MARK: - Listening

/// Listens through the microphone and passes on what it hears as text, for
/// the voice commands. Recognition happens on the phone when it can.
@MainActor
final class VoiceListener {
    enum Failure: LocalizedError {
        case unavailable
        case noMicrophone

        var errorDescription: String? {
            switch self {
            case .unavailable: "Speech recognition isn't available right now."
            case .noMicrophone: "The microphone isn't available."
            }
        }
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    /// What's heard so far, as it's recognized, until recognition stops on
    /// its own (it does after a while) or `stop()` is called.
    func start() throws -> AsyncThrowingStream<String, any Error> {
        stop()
        guard let recognizer, recognizer.isAvailable else { throw Failure.unavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .confirmation
        request.contextualStrings = VoiceCommand.vocabulary
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.feeding(RequestBox(request)))
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }

        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        task = recognizer.recognitionTask(with: request, resultHandler: Self.reporting(to: continuation))
        self.request = request
        return stream
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    nonisolated private static func feeding(_ box: RequestBox) -> AVAudioNodeTapBlock {
        { buffer, _ in box.request.append(buffer) }
    }

    nonisolated private static func reporting(
        to continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            if let result {
                continuation.yield(result.bestTranscription.formattedString)
                if result.isFinal { continuation.finish() }
            }
            if let error { continuation.finish(throwing: error) }
        }
    }
}

/// The recognition request, for the audio tap's thread. Appending audio to
/// it from there is what it's made for.
private final class RequestBox: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest

    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }
}

// MARK: - Audio session and permission

@MainActor
enum HandsFreeAudioSession {
    /// Asks, the first time, for speech recognition and the microphone.
    static func requestPermission() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization(Self.resuming(continuation))
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Speaking and listening at once, out of the speaker unless headphones
    /// are in, and through AirPods' microphone when they are. Other apps'
    /// audio pauses.
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setActive(true)
    }

    /// Back to the review screen's own audio setting.
    static func deactivate() {
        let playInSilent = UserDefaults.standard.bool(forKey: ReviewPreferences.Keys.playAudioInSilentMode)
        ReviewAudioSession.apply(playInSilent: playInSilent)
    }

    /// With headphones, the microphone doesn't hear the voice reading the
    /// card, so a command can cut the reading short. Out of the speaker it
    /// would, so listening waits until the reading ends.
    static var canListenWhileSpeaking: Bool {
        let headphones: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { headphones.contains($0.portType) }
    }

    nonisolated private static func resuming(
        _ continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>
    ) -> @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void {
        { status in continuation.resume(returning: status) }
    }
}
#endif
