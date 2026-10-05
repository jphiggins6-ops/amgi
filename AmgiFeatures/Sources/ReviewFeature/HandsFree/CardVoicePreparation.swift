//
//  CardVoicePreparation.swift
//  ReviewFeature
//

#if canImport(UIKit)
public import Foundation
public import Observation
import UIKit
import AnkiKit
import AppCore
import MnemonicCore
import ReviewCore

/// Settings → Review → AI Voice → Prepare Cards: the AI voice's script and
/// recordings made ahead for the cards hands-free mode would read in it, so
/// they don't have to wait for them.
///
/// The cards still to do are found soonest due first (`CardVoiceSides
/// .cardIdsByDueDate`), a batch of them is queued (the next 50, the next
/// 100, or all), and the queue is worked through one card at a time. It's
/// kept between launches: when Google's daily limit for the key is reached
/// (about 100 recordings, roughly 50 cards) it waits for the next day and
/// carries on by itself whenever Amgi opens; it also waits while hands-free
/// mode runs, which makes its own cards ready. A wait of a minute, when
/// Google asks for one, is waited out.
@MainActor
@Observable
public final class CardVoicePreparation {
    public static let shared = CardVoicePreparation()

    public enum Phase: Equatable, Sendable {
        case idle
        /// Rendering the cards to find the ones still to do.
        case checking
        /// Found them, soonest due first; waiting for a batch to be chosen.
        case choosing(toDo: Int, ready: Int)
        case preparing(done: Int, of: Int)
        /// Cards are queued, held up.
        case waiting(queued: Int, why: Wait)
        /// How it went.
        case finished(String)
    }

    /// Why the queued cards wait.
    public enum Wait: Equatable, Sendable {
        /// Google's daily limit for the key, until `until`; `message` is
        /// what Google said, with what it means.
        case dailyLimit(until: Date, message: String)
        case stopped
        case noConnection
        /// Three cards in a row couldn't be done; the last one's reason.
        case problems(String)

        /// A line for Settings.
        public var status: String {
            switch self {
            case .dailyLimit(let until, _):
                let time = until.formatted(date: .omitted, time: .shortened)
                let when = Calendar.current.isDateInToday(until) ? "at \(time)" : "tomorrow at \(time)"
                return "Google’s daily limit reached. Carries on \(when)."
            case .stopped:
                return "Stopped."
            case .noConnection:
                return "No connection. Carries on the next time Amgi opens."
            case .problems:
                return "Stopped: three cards in a row couldn’t be done."
            }
        }

        /// More about it, for underneath.
        public var note: String {
            switch self {
            case .dailyLimit(_, let message):
                return message + " Google’s day ends at midnight in California; the queue carries on by itself whenever Amgi is open after that."
            case .stopped:
                return "The rest stay queued, soonest due first. Carry On Now starts them again."
            case .noConnection:
                return "The card that was being made stays first in line."
            case .problems(let reason):
                return reason
            }
        }
    }

    public private(set) var phase: Phase = .idle
    /// Stop was tapped; the card under way is finished first.
    public private(set) var isStopping = false

    /// Roughly what a card costs: its rewrite and two recordings.
    public static let costPerCard = 0.002
    /// Batches to choose from, besides all of them.
    public static let batchSizes = [50, 100]

    @ObservationIgnored private var work: Task<Void, Never>?
    /// The cards `check()` found still to do, soonest due first.
    @ObservationIgnored private var found: [CardID] = []
    @ObservationIgnored private var handsFreeIsOn = false
    @ObservationIgnored private var madeRecorder: AIVoiceRecorder?

    private var recorder: AIVoiceRecorder {
        if let madeRecorder { return madeRecorder }
        let made = AIVoiceRecorder()
        madeRecorder = made
        return made
    }

    /// The cards queued, soonest due first, kept between launches.
    private var queue: [CardID] {
        get {
            let ids = UserDefaults.standard.array(forKey: ReviewPreferences.Keys.aiVoiceQueue) as? [Int64] ?? []
            return ids.map { CardID($0) }
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: ReviewPreferences.Keys.aiVoiceQueue)
        }
    }

    private init() {}

    public var isWorking: Bool {
        switch phase {
        case .checking, .preparing: true
        case .idle, .choosing, .waiting, .finished: false
        }
    }

    /// The cards to do, and how; nil when the AI voice is off.
    private struct Plan {
        let voice: String
        let rewrites: Bool
        /// Cards added before this are left to the iPhone voice.
        let since: Date

        static var current: Plan? {
            let cards = ReviewPreferences.aiVoiceCards
            guard cards != .off else { return nil }
            return Plan(
                voice: ReviewPreferences.aiVoice.rawValue,
                rewrites: ReviewPreferences.aiVoiceRewrites,
                since: cards == .all ? .distantPast : ReviewPreferences.aiVoiceSince
            )
        }

        /// A card's id is the moment it was added, in milliseconds.
        func includes(_ cardId: CardID) -> Bool {
            Double(cardId.rawValue) / 1000 >= since.timeIntervalSince1970
        }
    }

    // MARK: - Choosing a batch

    /// Finds the cards still to do, soonest due first, then waits for a
    /// batch to be chosen (`queueBatch`).
    public func check() {
        guard !isWorking else { return }
        guard let plan = Plan.current else {
            phase = .finished("Choose which cards the AI voice reads first.")
            return
        }
        guard recorder.hasKey else {
            phase = .finished(CardVoiceError.noKey.localizedDescription)
            return
        }
        phase = .checking
        CardVoiceLog.shared.add("Finding the cards due soonest that don’t have the AI voice")
        work = Task {
            let sides = CardVoiceSides()
            do {
                // New cards come in at today's rate.
                let newPerDay = TodaySnapshotStore.read()?.newTotal ?? 20
                var toDo: [CardID] = []
                var ready = 0
                for cardId in try await sides.cardIdsByDueDate(newPerDay: newPerDay) where plan.includes(cardId) {
                    guard !Task.isCancelled else { return }
                    guard let html = await sides.sides(of: cardId) else { continue }
                    let card = VoiceCard(front: html.front, back: html.back, deckName: "")
                    guard !card.written.question.isEmpty else { continue }
                    if recorder.isReady(card, voice: plan.voice, rewrites: plan.rewrites) {
                        ready += 1
                    } else {
                        toDo.append(cardId)
                    }
                }
                found = toDo
                CardVoiceLog.shared.add("Found \(toDo.count) cards without the AI voice; \(ready) have it")
                phase = toDo.isEmpty
                    ? .finished("All \(ready) cards have the AI voice.")
                    : .choosing(toDo: toDo.count, ready: ready)
            } catch {
                phase = .finished("The cards couldn't be listed: \(error.localizedDescription)")
            }
        }
    }

    /// Queues the first `count` cards found, soonest due first, in place of
    /// any queue there was, and starts on them.
    public func queueBatch(_ count: Int) {
        guard case .choosing = phase else { return }
        queue = Array(found.prefix(count))
        found = []
        phase = .idle
        CardVoiceLog.shared.add("Queued the next \(queue.count) cards due")
        // A choice made just now: worth a try even past yesterday's limit.
        AIVoiceRecorder.clearPause()
        run(keepingScreenOn: true)
    }

    /// Leaves the cards found for another time.
    public func cancelChoosing() {
        guard case .choosing = phase else { return }
        found = []
        phase = queue.isEmpty ? .idle : .waiting(queued: queue.count, why: .stopped)
    }

    // MARK: - The queue

    /// Carries on with the cards queued, when nothing holds them up: when
    /// Amgi opens, and when hands-free ends.
    public func resume() {
        guard !isWorking, !queue.isEmpty else { return }
        if handsFreeIsOn { return }
        if let wait = Self.dailyLimitWait {
            phase = .waiting(queued: queue.count, why: wait)
            return
        }
        guard Plan.current != nil, recorder.hasKey else { return }
        CardVoiceLog.shared.add("Carrying on with \(queue.count) queued cards")
        run(keepingScreenOn: false)
    }

    /// Starts again on the cards queued, with the screen kept on. Past
    /// Google's daily limit too, as it may have been raised (billing
    /// turned on, say): if not, it's back to waiting after one try.
    public func carryOn() {
        guard !isWorking else { return }
        AIVoiceRecorder.clearPause()
        CardVoiceLog.shared.add("Carrying on with \(queue.count) queued cards, as asked")
        run(keepingScreenOn: true)
    }

    /// Stops after the card under way; the rest stay queued.
    public func stop() {
        switch phase {
        case .checking:
            work?.cancel()
            phase = queue.isEmpty ? .idle : .waiting(queued: queue.count, why: .stopped)
        case .preparing:
            isStopping = true
            work?.cancel()
        case .idle, .choosing, .waiting, .finished:
            break
        }
    }

    /// Empties the queue.
    public func clearQueue() {
        guard !isWorking else { return }
        queue = []
        phase = .idle
    }

    func handsFreeStarted() {
        handsFreeIsOn = true
        if case .preparing = phase {
            CardVoiceLog.shared.add("Waiting while hands-free runs: it makes its own cards ready", .waiting)
        }
    }

    func handsFreeStopped() {
        handsFreeIsOn = false
        resume()
    }

    /// Waiting for Google's daily limit to pass, while it holds.
    private static var dailyLimitWait: Wait? {
        guard AIVoiceRecorder.isPaused, let pause = AIVoiceRecorder.pause, pause.daily else { return nil }
        return .dailyLimit(until: pause.until, message: pause.reason)
    }

    private func run(keepingScreenOn: Bool) {
        guard !isWorking, let plan = Plan.current else { return }
        let total = queue.count
        guard total > 0 else { return }
        isStopping = false
        phase = .preparing(done: 0, of: total)
        // A locked phone would pause the work.
        if keepingScreenOn { ScreenAwake.keep(.preparing) }
        work = Task {
            let ending = await workThroughQueue(plan: plan, total: total)
            ScreenAwake.keep(.preparing, false)
            isStopping = false
            phase = ending
        }
    }

    /// One card at a time, so Google's limits are met one request at a
    /// time. A card leaves the queue once it's done, or once it can't be.
    private func workThroughQueue(plan: Plan, total: Int) async -> Phase {
        let sides = CardVoiceSides()
        var done = 0
        var failed = 0
        var failuresInARow = 0
        while let cardId = queue.first {
            // Hands-free makes its own cards ready meanwhile.
            while handsFreeIsOn, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
            }
            if Task.isCancelled {
                CardVoiceLog.shared.add("Stopped, with \(queue.count) cards still queued")
                return .waiting(queued: queue.count, why: .stopped)
            }
            if let wait = Self.dailyLimitWait {
                CardVoiceLog.shared.add("Waiting for Google’s daily limit to pass: \(queue.count) cards still queued", .waiting)
                return .waiting(queued: queue.count, why: wait)
            }
            // Gone, or no words to read: nothing to do.
            guard let html = await sides.sides(of: cardId) else {
                queue.removeFirst()
                continue
            }
            let card = VoiceCard(front: html.front, back: html.back, deckName: "")
            if card.written.question.isEmpty || recorder.isReady(card, voice: plan.voice, rewrites: plan.rewrites) {
                queue.removeFirst()
                done += 1
                phase = .preparing(done: done, of: total)
                continue
            }

            var made = await recorder.make(card, voice: plan.voice, rewrites: plan.rewrites)
            // Google asked for a pause: wait out the minute, then try again.
            var waits = 0
            while !made, waits < 5, let pause = AIVoiceRecorder.pause, !pause.daily, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(1, pause.until.timeIntervalSinceNow)))
                made = await recorder.make(card, voice: plan.voice, rewrites: plan.rewrites)
                waits += 1
            }

            if made {
                queue.removeFirst()
                done += 1
                failuresInARow = 0
            } else if let wait = Self.dailyLimitWait {
                // The card stays first in line for tomorrow.
                CardVoiceLog.shared.add("Waiting for Google’s daily limit to pass: \(queue.count) cards still queued", .waiting)
                return .waiting(queued: queue.count, why: wait)
            } else if recorder.lastError is URLError {
                CardVoiceLog.shared.add("The connection dropped: \(queue.count) cards still queued", .waiting)
                return .waiting(queued: queue.count, why: .noConnection)
            } else {
                queue.removeFirst()
                failed += 1
                failuresInARow += 1
                if failuresInARow >= 3 {
                    CardVoiceLog.shared.add("Stopped after three cards in a row couldn’t be done", .problem)
                    return .waiting(queued: queue.count, why: .problems(recorder.problem ?? ""))
                }
            }
            phase = .preparing(done: done, of: total)
        }
        if failed > 0 {
            CardVoiceLog.shared.add("Queue done: \(done) ready, \(failed) couldn’t be done", .done)
            return .finished("Done: \(done) cards have the AI voice; \(failed) couldn’t be done and are left to the iPhone voice. \(recorder.problem ?? "")")
        }
        CardVoiceLog.shared.add("Queue done: \(done) cards ready", .done)
        return .finished("Done: \(done) cards have the AI voice.")
    }
}

/// Keeps the screen from locking while anything wants it on: hands-free
/// mode (Settings → Review → Hands-Free → Keep the screen on), or cards
/// being made ready for the AI voice.
@MainActor
enum ScreenAwake {
    enum Holder: Hashable {
        case handsFree
        case preparing
    }

    private static var holders: Set<Holder> = []

    static func keep(_ holder: Holder, _ on: Bool = true) {
        if on {
            holders.insert(holder)
        } else {
            holders.remove(holder)
        }
        UIApplication.shared.isIdleTimerDisabled = !holders.isEmpty
    }
}
#endif
