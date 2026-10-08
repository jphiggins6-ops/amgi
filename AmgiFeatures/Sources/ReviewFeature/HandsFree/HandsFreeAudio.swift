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
///
/// With `playback`, both go through hands-free's own audio engine, beside
/// the microphone, so the iPhone's echo cancelling knows what's being
/// played and takes it out of what the microphone hears.
@MainActor
final class CardSpeaker {
    var speed: HandsFreeSpeed = .normal
    /// The iPhone voice picked in Settings, for text in its language; the
    /// best one installed when nil.
    var preferredVoice: String? {
        didSet { voices = [:] }
    }
    /// Hands-free's engine output, while echo cancelling is on.
    var playback: EnginePlayback?
    /// The engine playing under way, and whether its end is scheduled.
    private var engineGeneration: Int?
    private var endScheduled = false

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
                let engine = playback.flatMap { $0.canPlay ? $0 : nil }
                let generation = engine?.begin(rate: 1)
                engineGeneration = generation
                for segment in segments {
                    let utterance = AVSpeechUtterance(string: segment.text)
                    utterance.voice = voice(for: segment.script)
                    utterance.rate = Self.rate(for: speed)
                    utterance.postUtteranceDelay = 0.05
                    let id = ObjectIdentifier(utterance)
                    queued.insert(id)
                    last = id
                    if let engine, let generation {
                        synthesizer.write(
                            utterance,
                            toBufferCallback: Self.writing(
                                to: engine,
                                generation: generation,
                                utterance: id,
                                ended: Self.forwardingWritten(to: self)
                            )
                        )
                    } else {
                        synthesizer.speak(utterance)
                    }
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
        if let playback, playback.canPlay {
            return await playThroughEngine(recording, playback)
        }
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

    private func playThroughEngine(_ recording: URL, _ playback: EnginePlayback) async -> Bool {
        guard let audio = Self.audio(of: recording) else { return false }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                let generation = playback.begin(rate: Self.playbackRate(for: speed))
                engineGeneration = generation
                endScheduled = true
                playback.schedule(audio, generation: generation)
                playback.scheduleEnd(generation: generation, done: Self.forwardingPlayedBack(to: self, generation: generation))
            }
        } onCancel: {
            Self.stopSoon(self)
        }
        return true
    }

    /// Stops at once and lets a waiting `speak` or `play` return.
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        player?.stop()
        player = nil
        playback?.stop()
        finish()
    }

    /// An utterance is done: spoken, or, through the engine, all written
    /// out (`written`), or said by the synthesizer to be finished, which
    /// can come before the last of its sound has been handed over.
    fileprivate func ended(_ utterance: ObjectIdentifier, cancelled: Bool, written: Bool = false) {
        guard queued.contains(utterance) else { return }
        if cancelled {
            finish()
            return
        }
        guard utterance == last else { return }
        guard let playback, let generation = engineGeneration else {
            finish()
            return
        }
        if written {
            scheduleEnd(playback, generation)
        } else {
            // In case the end of the writing never comes.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.engineGeneration == generation else { return }
                self.scheduleEnd(playback, generation)
            }
        }
    }

    private func scheduleEnd(_ playback: EnginePlayback, _ generation: Int) {
        guard !endScheduled else { return }
        endScheduled = true
        playback.scheduleEnd(generation: generation, done: Self.forwardingPlayedBack(to: self, generation: generation))
    }

    /// The engine has played everything up to the end of `generation`.
    fileprivate func playedBack(_ generation: Int) {
        guard engineGeneration == generation else { return }
        finish()
    }

    fileprivate func playbackEnded(_ finished: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == finished else { return }
        self.player = nil
        finish()
    }

    private func finish() {
        queued = []
        last = nil
        engineGeneration = nil
        endScheduled = false
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

    /// What the synthesizer writes out for an utterance, handed to the
    /// engine; an empty buffer marks its end.
    nonisolated private static func writing(
        to playback: EnginePlayback,
        generation: Int,
        utterance: ObjectIdentifier,
        ended: @escaping @Sendable (ObjectIdentifier) -> Void
    ) -> @Sendable (AVAudioBuffer) -> Void {
        { buffer in
            guard let sound = buffer as? AVAudioPCMBuffer else { return }
            if sound.frameLength == 0 {
                ended(utterance)
            } else {
                playback.schedule(sound, generation: generation)
            }
        }
    }

    nonisolated private static func forwardingWritten(to speaker: CardSpeaker) -> @Sendable (ObjectIdentifier) -> Void {
        { [weak speaker] utterance in
            guard let speaker else { return }
            Task { @MainActor in speaker.ended(utterance, cancelled: false, written: true) }
        }
    }

    nonisolated private static func forwardingPlayedBack(to speaker: CardSpeaker, generation: Int) -> @Sendable () -> Void {
        { [weak speaker] in
            guard let speaker else { return }
            Task { @MainActor in speaker.playedBack(generation) }
        }
    }

    /// A recording's sound, read whole: a card side is a few seconds.
    nonisolated private static func audio(of recording: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: recording), file.length > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(min(file.length, 48_000 * 600))
              )
        else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        return buffer.frameLength > 0 ? buffer : nil
    }
}

// MARK: - Playing through the engine

/// Hands-free's reading, played through the same audio engine as the
/// microphone while the iPhone's echo cancelling (its voice processing) is
/// on: the canceller then knows what's being played and takes it out of
/// what the microphone hears, so you can answer over the reading, out of
/// the speaker or in the car. Everything is turned into one format first,
/// and recordings are sped up or slowed by `rate`.
final class EnginePlayback: @unchecked Sendable {
    let format: AVAudioFormat
    private let player = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let lock = NSLock()
    private var generation = 0
    private var converters: [String: AVAudioConverter] = [:]

    init?(engine: AVAudioEngine) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else { return nil }
        self.format = format
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
    }

    /// Whether the engine is running, to play through.
    var canPlay: Bool {
        player.engine?.isRunning == true
    }

    /// Stops what's playing and starts afresh at `rate`; what's scheduled
    /// for the number returned plays, anything older is dropped.
    func begin(rate: Float) -> Int {
        lock.withLock {
            generation += 1
            player.stop()
            pitch.rate = rate
            for converter in converters.values { converter.reset() }
            if player.engine?.isRunning == true { player.play() }
            return generation
        }
    }

    func stop() {
        lock.withLock {
            generation += 1
            player.stop()
        }
    }

    func schedule(_ buffer: AVAudioPCMBuffer, generation: Int) {
        lock.withLock {
            guard generation == self.generation, buffer.frameLength > 0, let sound = converted(buffer) else { return }
            player.scheduleBuffer(sound, completionHandler: nil)
        }
    }

    /// `done` once everything scheduled before it has been heard, or at
    /// once when `generation` has been stopped.
    func scheduleEnd(generation: Int, done: @escaping @Sendable () -> Void) {
        lock.withLock {
            guard generation == self.generation,
                  let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)
            else {
                done()
                return
            }
            marker.frameLength = 1
            player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack) { _ in done() }
        }
    }

    /// `buffer` in the engine's format, by a converter kept for its own
    /// format, so a voice's sound runs on smoothly from buffer to buffer.
    private func converted(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        let source = buffer.format
        let key = "\(source.sampleRate)/\(source.channelCount)/\(source.commonFormat.rawValue)/\(source.isInterleaved)"
        let converter: AVAudioConverter
        if let known = converters[key] {
            converter = known
        } else {
            guard let made = AVAudioConverter(from: source, to: format) else { return nil }
            converters[key] = made
            converter = made
        }
        let frames = (Double(buffer.frameLength) * format.sampleRate / source.sampleRate).rounded(.up)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames) + 64) else { return nil }
        let input = ConverterInput(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            input.next(inputStatus)
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Hands a converter one buffer, then says there's no more for now.
private final class ConverterInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
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
///
/// The microphone stays on from `open()` to `close()`, the whole of
/// hands-free, and `start()` and `stop()` only begin and end a recognition
/// of what it hears. iPhone lets an app keep the microphone it has when the
/// screen locks, but not turn it on then, so switching it off between
/// cards ended hands-free the first time the screen locked.
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
    /// Where the microphone's sound goes: the recognition under way, if any.
    private let route = AudioRoute()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    /// The hands-free word list the on-phone recognizer favours, once it's
    /// ready; see `CommandModel`.
    private var commandModel: SFSpeechLanguageModel.Configuration?
    private var preparingModel = false

    /// Whether the iPhone's voice processing is on for the microphone:
    /// echo cancelling, noise suppression and level keeping, as for calls.
    /// With it, the reading is played through `playback`, and what the
    /// microphone hears has the reading taken out.
    private(set) var cancelsEcho = false
    /// The engine's output, for `CardSpeaker`, while `cancelsEcho`.
    var playback: EnginePlayback? {
        cancelsEcho ? enginePlayback : nil
    }
    private var enginePlayback: EnginePlayback?

    /// Turns the microphone on, unless it's on: with voice processing when
    /// Settings has echo cancelling on, and without when that can't start.
    func open() throws {
        guard !engine.isRunning else { return }
        prepareCommandModel()
        let wanted = ReviewPreferences.handsFreeEchoCancelling
        do {
            try start(processingVoice: wanted)
        } catch where wanted {
            try start(processingVoice: false)
        }
    }

    private func start(processingVoice: Bool) throws {
        if engine.isRunning { engine.stop() }
        // Off since it was opened (a call, or headphones coming out), or
        // voice processing switched: the sound may come in another format.
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != processingVoice {
            do {
                try input.setVoiceProcessingEnabled(processingVoice)
            } catch {
                if processingVoice { throw error }
            }
        }
        cancelsEcho = input.isVoiceProcessingEnabled
        if cancelsEcho, enginePlayback == nil {
            enginePlayback = EnginePlayback(engine: engine)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.feeding(route))
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            close()
            throw error
        }
    }

    /// Readies the word list in the background, the first time; the
    /// listening carries on without it until then, or if it can't be made.
    private func prepareCommandModel() {
        guard commandModel == nil, !preparingModel else { return }
        preparingModel = true
        Task { [weak self] in
            let ready = await CommandModel.prepare()
            guard let self else { return }
            self.preparingModel = false
            if ready {
                self.commandModel = CommandModel.configuration
            }
        }
    }

    /// Turns the microphone off, ending any recognition.
    func close() {
        stop()
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    /// What's heard from now on, as it's recognized, until recognition
    /// stops on its own (it does after a while) or `stop()` is called.
    func start() throws -> AsyncThrowingStream<[String], any Error> {
        stop()
        guard let recognizer, recognizer.isAvailable else { throw Failure.unavailable }
        try open()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .confirmation
        request.contextualStrings = VoiceCommand.vocabulary
        request.addsPunctuation = false
        // On the phone it's quick and private, and favours the commands
        // from its own word list; Apple's servers, with Sharper listening
        // on, catch more in some places.
        if recognizer.supportsOnDeviceRecognition, !ReviewPreferences.handsFreeSharperListening {
            request.requiresOnDeviceRecognition = true
            if let commandModel {
                request.customizedLanguageModel = commandModel
            }
        }
        route.send(to: request)

        let (stream, continuation) = AsyncThrowingStream<[String], any Error>.makeStream()
        task = recognizer.recognitionTask(with: request, resultHandler: Self.reporting(to: continuation))
        self.request = request
        return stream
    }

    /// Ends the recognition under way; the microphone stays on.
    func stop() {
        // First, so no more sound goes to the request once it's ended.
        route.send(to: nil)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    nonisolated private static func feeding(_ route: AudioRoute) -> AVAudioNodeTapBlock {
        { buffer, _ in route.append(buffer) }
    }

    nonisolated private static func reporting(
        to continuation: AsyncThrowingStream<[String], any Error>.Continuation
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            if let result {
                // The best guess first, then the next few: a command missed
                // in the first ("heart") is often in the next ("hard").
                let guesses = result.transcriptions.prefix(4).map(\.formattedString)
                continuation.yield(guesses.isEmpty ? [result.bestTranscription.formattedString] : guesses)
                if result.isFinal { continuation.finish() }
            }
            if let error { continuation.finish(throwing: error) }
        }
    }
}

/// The hands-free commands as a word list of the on-phone recognizer's
/// own (Apple's custom language models), so a lone "good" or "hard" is
/// taken for the command rather than for any word that sounds like it.
/// Made on the phone the first time, then kept.
enum CommandModel {
    static let identifier = "com.amgi.handsfree.commands"
    /// Changed whenever `VoiceCommand.trainingPhrases` change.
    static let version = "1"

    private static var folder: URL {
        URL.cachesDirectory.appending(path: "HandsFreeCommands", directoryHint: .isDirectory)
    }

    static var configuration: SFSpeechLanguageModel.Configuration {
        SFSpeechLanguageModel.Configuration(
            languageModel: folder.appending(path: "LM-\(version)"),
            vocabulary: folder.appending(path: "Vocab-\(version)")
        )
    }

    /// Writes the word list out and has the recognizer take it in, off the
    /// main thread; false when that can't be done here.
    @concurrent static func prepare() async -> Bool {
        let asset = folder.appending(path: "commands-\(version).bin")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: asset.path) {
                let data = SFCustomLanguageModelData(
                    locale: Locale(identifier: "en-US"),
                    identifier: identifier,
                    version: version
                )
                for entry in VoiceCommand.trainingPhrases {
                    data.insert(phraseCount: SFCustomLanguageModelData.PhraseCount(phrase: entry.phrase, count: entry.weight))
                }
                try await data.export(to: asset)
            }
            try await SFSpeechLanguageModel.prepareCustomLanguageModel(
                for: asset,
                clientIdentifier: identifier,
                configuration: configuration
            )
            return true
        } catch {
            return false
        }
    }
}

/// The recognition request the microphone's sound goes to, for the audio
/// tap's thread, which appends to it while the main actor changes it.
private final class AudioRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func send(to request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock { self.request = request }
    }

    /// Under the lock, so a request that's been let go gets nothing more.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
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
