//
//  CardVoicePreparation.swift
//  ReviewFeature
//

#if canImport(UIKit)
import BackgroundTasks
import OSLog
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
        case noKey
        /// Three cards in a row couldn't be done; the last one's reason.
        case problems(String)
        /// In the background, where the iPhone's speech recognition, which
        /// checks the pieces of recordings made together, doesn't run.
        case needsAmgiOpen

        /// A line for Settings.
        public var status: String {
            switch self {
            case .dailyLimit(let until, _):
                let time = until.formatted(date: .omitted, time: .shortened)
                let when = Calendar.current.isDateInToday(until) ? "at \(time)" : "tomorrow at \(time)"
                return "Google’s daily limit reached. Carries on \(when), or sooner if the limit is raised."
            case .stopped:
                return "Stopped."
            case .noConnection:
                return "No connection. Carries on the next time Amgi opens."
            case .noKey:
                return "No Gemini key."
            case .problems:
                return "Stopped: three cards in a row couldn’t be done."
            case .needsAmgiOpen:
                return "Carries on when Amgi is open."
            }
        }

        /// More about it, for underneath.
        public var note: String {
            switch self {
            case .dailyLimit(_, let message):
                return message + " Google’s day ends at midnight in California, and the queue carries on by itself once Amgi is open after that. If the limit is raised sooner (billing turned on, say), Try Again Now carries on straight away; Amgi also tries again by itself an hour after Google said no, while it’s open."
            case .stopped:
                return "The rest stay queued, soonest due first. Carry On Now starts them again."
            case .noConnection:
                return "The card that was being made stays first in line."
            case .noKey:
                return CardVoiceError.noKey.localizedDescription
            case .problems(let reason):
                return reason
            case .needsAmgiOpen:
                return "The iPhone’s speech recognition, which checks each piece of a recording made of several cards, doesn’t run while Amgi is in the background, so the cards wait for Amgi to be open. Nothing was spent on them meanwhile."
            }
        }
    }

    /// How many of the cards the AI voice reads have it: counted now and
    /// then (`countIfStale`), and kept up as cards are made ready.
    public struct Tally: Codable, Equatable, Sendable {
        /// Cards with both sides recorded.
        public fileprivate(set) var voiced: Int
        /// The cards the AI voice reads that have words to read; suspended
        /// cards aren't counted.
        public let total: Int
        /// What they were counted for: the voice, whether cards are
        /// rewritten, and the cards added since when.
        let voice: String
        let rewrites: Bool
        let since: Date
        /// When they were last all counted.
        let counted: Date

        init(voiced: Int, total: Int, voice: String, rewrites: Bool, since: Date, counted: Date = Date()) {
            self.voiced = voiced
            self.total = total
            self.voice = voice
            self.rewrites = rewrites
            self.since = since
            self.counted = counted
        }

        public var remaining: Int { max(total - voiced, 0) }
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
    /// Trying again by itself, while Google's daily limit holds.
    @ObservationIgnored private var wakeUp: Task<Void, Never>?

    /// The last count of the cards with the AI voice, kept between launches.
    public private(set) var tally: Tally?
    /// The cards are being counted.
    public private(set) var isCounting = false
    @ObservationIgnored private var counting: Task<Void, Never>?
    /// Which count is the latest, so one stopped doesn't overwrite it.
    @ObservationIgnored private var countingID = UUID()

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

    private init() {
        tally = Self.savedTally()
    }

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

        /// Whether `tally` counted these cards in this voice.
        func matches(_ tally: Tally) -> Bool {
            tally.voice == voice && tally.rewrites == rewrites
                && abs(tally.since.timeIntervalSince(since)) < 1
        }

        func tally(voiced: Int, total: Int) -> Tally {
            Tally(voiced: voiced, total: total, voice: voice, rewrites: rewrites, since: since)
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
        stopCounting()
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
                keep(plan.tally(voiced: ready, total: ready + toDo.count))
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

    // MARK: - Counting

    /// The count for the voice and cards chosen now; nil until they're
    /// counted.
    public var currentTally: Tally? {
        guard let tally, let plan = Plan.current, plan.matches(tally) else { return nil }
        return tally
    }

    /// Counts the cards the AI voice reads and how many have it, unless
    /// that was done in the last couple of minutes for the same voice and
    /// cards, or cards are being made ready, which keeps the count up.
    public func countIfStale() {
        if let tally = currentTally, isWorking || tally.counted.timeIntervalSinceNow > -120 { return }
        guard !isCounting else { return }
        countAgain()
    }

    /// Counts the cards again now, in place of any count under way.
    public func countAgain() {
        guard let plan = Plan.current else { return }
        // The check counts them on its way.
        if case .checking = phase { return }
        startCounting(plan)
    }

    /// The recordings are gone: no card has the AI voice.
    public func recordingsDeleted() {
        guard var updated = tally else { return }
        updated.voiced = 0
        keep(updated)
    }

    /// One more card has the AI voice, made just now by the queue or by
    /// hands-free mode: counted without counting them all again.
    func cardVoiced(voice: String, rewrites: Bool) {
        guard var updated = tally, updated.voice == voice, updated.rewrites == rewrites else { return }
        updated.voiced = min(updated.voiced + 1, updated.total)
        keep(updated)
    }

    private func startCounting(_ plan: Plan) {
        stopCounting()
        let id = UUID()
        countingID = id
        isCounting = true
        counting = Task {
            let result = await tallyCards(plan)
            guard countingID == id else { return }
            counting = nil
            isCounting = false
            guard let counted = result else { return }
            if counted.voiced != tally?.voiced || counted.total != tally?.total {
                CardVoiceLog.shared.add("Counted: \(counted.voiced) of \(counted.total) cards have the AI voice")
            }
            keep(counted)
        }
    }

    private func stopCounting() {
        counting?.cancel()
        counting = nil
        countingID = UUID()
        isCounting = false
    }

    /// How many of the cards the AI voice reads have it, by the same rules
    /// as `check()`; nil when stopped, or when the cards can't be listed.
    private func tallyCards(_ plan: Plan) async -> Tally? {
        let sides = CardVoiceSides()
        guard let ids = try? await sides.cardIds() else { return nil }
        var total = 0
        var voiced = 0
        for cardId in ids where plan.includes(cardId) {
            if Task.isCancelled { return nil }
            guard let html = await sides.sides(of: cardId) else { continue }
            let card = VoiceCard(front: html.front, back: html.back, deckName: "")
            guard !card.written.question.isEmpty else { continue }
            total += 1
            if recorder.isReady(card, voice: plan.voice, rewrites: plan.rewrites) {
                voiced += 1
            }
        }
        return plan.tally(voiced: voiced, total: total)
    }

    private func keep(_ newTally: Tally) {
        tally = newTally
        UserDefaults.standard.set(try? JSONEncoder().encode(newTally), forKey: Self.tallyKey)
    }

    private static let tallyKey = "ai_voice_tally"

    private static func savedTally() -> Tally? {
        guard let data = UserDefaults.standard.data(forKey: tallyKey) else { return nil }
        return try? JSONDecoder().decode(Tally.self, from: data)
    }

    // MARK: - The queue

    /// Queues any new cards still to do (`queueNewCards`), then carries on
    /// with the cards queued, when nothing holds them up: when Amgi opens,
    /// when hands-free ends, and when Google's daily limit may have passed.
    /// Asks iOS for time overnight too, while there's work.
    public func resume() {
        guard !isLookingForNewCards else { return }
        isLookingForNewCards = true
        Task {
            await queueNewCards()
            isLookingForNewCards = false
            resumeQueue()
            if ReviewPreferences.aiVoiceAutoPrepare || !queue.isEmpty {
                CardVoiceBackground.scheduleOvernight()
            }
        }
    }

    private func resumeQueue() {
        guard !isWorking, !queue.isEmpty else { return }
        if handsFreeIsOn { return }
        if let wait = Self.dailyLimitWait {
            // The limit may have been raised since Google said no (billing
            // turned on, say): an hour on, it's worth one more try.
            if let reached = AIVoiceRecorder.dailyLimitReachedAt,
               reached.timeIntervalSinceNow > -Self.retryAfter {
                settle(.waiting(queued: queue.count, why: wait))
                return
            }
            AIVoiceRecorder.clearPause()
            CardVoiceLog.shared.add("Trying again: Google’s daily limit may have been raised since it last said no")
        }
        guard Plan.current != nil, recorder.hasKey else { return }
        CardVoiceLog.shared.add("Carrying on with \(queue.count) queued cards")
        run(keepingScreenOn: true)
    }

    /// How long after Google's daily limit it tries again by itself.
    private static let retryAfter: TimeInterval = 60 * 60

    // MARK: - New cards, by themselves

    @ObservationIgnored private var isLookingForNewCards = false

    /// Cards that don't have the AI voice yet, queued without Prepare
    /// Cards, while Settings → Review → AI Voice → Prepare new cards by
    /// itself is on: the first time, every card still to do, soonest due
    /// first; after that, the cards added since it last looked (a card's
    /// id is the moment it was added), behind those queued already.
    /// Whenever Amgi opens, and overnight.
    func queueNewCards() async {
        guard ReviewPreferences.aiVoiceAutoPrepare, !isWorking, let plan = Plan.current, recorder.hasKey else { return }
        if case .checking = phase { return }
        let sides = CardVoiceSides()
        let defaults = UserDefaults.standard
        let since = defaults.object(forKey: Self.newCardsSinceKey) as? Int64
        let ids: [CardID]
        do {
            if let since {
                ids = try await sides.cardIds()
                    .filter { $0.rawValue > since }
                    .sorted { $0.rawValue < $1.rawValue }
            } else {
                CardVoiceLog.shared.add("Looking for every card without the AI voice, to prepare them by themselves")
                let newPerDay = TodaySnapshotStore.read()?.newTotal ?? 20
                ids = try await sides.cardIdsByDueDate(newPerDay: newPerDay)
            }
        } catch {
            return
        }
        var queued = Set(queue)
        var found: [CardID] = []
        for cardId in ids where plan.includes(cardId) && !queued.contains(cardId) {
            if Task.isCancelled || isWorking { return }
            guard let html = await sides.sides(of: cardId) else { continue }
            let card = VoiceCard(front: html.front, back: html.back, deckName: "")
            guard !card.written.question.isEmpty,
                  !recorder.isReady(card, voice: plan.voice, rewrites: plan.rewrites)
            else { continue }
            found.append(cardId)
            queued.insert(cardId)
        }
        if let newest = ids.map(\.rawValue).max() {
            defaults.set(max(newest, since ?? 0), forKey: Self.newCardsSinceKey)
        } else if since == nil {
            defaults.set(Int64(0), forKey: Self.newCardsSinceKey)
        }
        guard !found.isEmpty else { return }
        queue += found
        CardVoiceLog.shared.add(since == nil
            ? "Queued \(found.count) cards without the AI voice, to be prepared by themselves"
            : "Queued \(found.count) new \(found.count == 1 ? "card" : "cards") for the AI voice")
    }

    /// The newest card looked at by `queueNewCards`, by id.
    private static let newCardsSinceKey = "ai_voice_new_cards_since"

    // MARK: - In the background

    /// What iOS lent for the work in the background, if anything.
    @ObservationIgnored private var lent: BackgroundTaskBox?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?

    /// For `AmgiRoot.bootstrap`: the overnight work has to be known to iOS
    /// before launch ends.
    public static func registerBackgroundWork() {
        CardVoiceBackground.register()
    }

    /// iOS's time overnight, on the charger (`CardVoiceBackground`): new
    /// cards found, then the queue worked through, until it's done, Google's
    /// limit is reached, or iOS wants the time back.
    func workOvernight(_ box: BackgroundTaskBox) async {
        box.task.expirationHandler = CardVoiceBackground.stopping()
        CardVoiceLog.shared.add("Working in the background while the iPhone charges")
        if !isWorking {
            await queueNewCards()
            resumeQueue()
        }
        await work?.value
        box.task.setTaskCompleted(success: true)
        if ReviewPreferences.aiVoiceAutoPrepare || !queue.isEmpty {
            CardVoiceBackground.scheduleOvernight()
        }
    }

    /// iOS 26 lets work started in Amgi carry on once it's left, with its
    /// progress shown by the system, as long as it keeps moving.
    private func carryOnWhenLeft(total: Int) {
        guard #available(iOS 26.0, *), UIApplication.shared.applicationState == .active else { return }
        CardVoiceBackground.submitContinued(cards: total)
    }

    /// iOS has started the work's time in the background.
    func continuedStarted(_ box: BackgroundTaskBox) {
        guard isWorking else {
            box.task.setTaskCompleted(success: true)
            return
        }
        lent = box
        box.task.expirationHandler = CardVoiceBackground.stopping()
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            // Progress at least every few seconds, as iOS ends work it
            // sees standing still: a card's share once it's done, and a
            // little in between while Gemini records.
            var lastDone = -1
            var ticks: Int64 = 0
            while !Task.isCancelled, let self, let lent = self.lent {
                if case .preparing(let done, let total) = self.phase {
                    ticks = done == lastDone ? min(ticks + 1, 99) : 0
                    lastDone = done
                    CardVoiceBackground.report(lent, done: done, of: total, ticks: ticks)
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The work is over: iOS's time is handed back.
    private func endBackgroundTime() {
        heartbeat?.cancel()
        heartbeat = nil
        lent?.task.setTaskCompleted(success: true)
        lent = nil
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
        settle(.idle)
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
        guard recorder.hasKey else {
            settle(.waiting(queued: total, why: .noKey))
            return
        }
        isStopping = false
        settle(.preparing(done: 0, of: total))
        // A locked phone would pause the work.
        if keepingScreenOn { ScreenAwake.keep(.preparing) }
        carryOnWhenLeft(total: total)
        let together = ReviewPreferences.aiVoiceTogether
        work = Task {
            let ending: Phase
            if together.cards > 0 {
                ending = await workThroughQueue(
                    plan: plan,
                    total: total,
                    cardsTogether: together.cards,
                    maxCharacters: together.maxCharacters
                )
            } else {
                ending = await workThroughQueue(plan: plan, total: total)
            }
            ScreenAwake.keep(.preparing, false)
            isStopping = false
            settle(ending)
            endBackgroundTime()
            // Made ready one by one meanwhile: counted again, to be sure.
            countAgain()
        }
    }

    /// Moves on to `newPhase`. While Google's daily limit holds, it tries
    /// again by itself when the limit may have changed, if Amgi is open:
    /// an hour after Google said no, or when Google's day ends.
    private func settle(_ newPhase: Phase) {
        phase = newPhase
        wakeUp?.cancel()
        wakeUp = nil
        guard case .waiting(_, .dailyLimit(let until, _)) = newPhase else { return }
        let retry = (AIVoiceRecorder.dailyLimitReachedAt ?? Date()).addingTimeInterval(Self.retryAfter)
        let delay = max(min(until, retry).timeIntervalSinceNow, 0) + 5
        wakeUp = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            wakeUp = nil
            resume()
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
        return finished(done: done, failed: failed)
    }

    private func finished(done: Int, failed: Int) -> Phase {
        if failed > 0 {
            CardVoiceLog.shared.add("Queue done: \(done) ready, \(failed) couldn’t be done", .done)
            return .finished("Done: \(done) cards have the AI voice; \(failed) couldn’t be done and are left to the iPhone voice. \(recorder.problem ?? "")")
        }
        CardVoiceLog.shared.add("Queue done: \(done) cards ready", .done)
        return .finished("Done: \(done) cards have the AI voice.")
    }

    /// A few cards at a time (Settings → Review → AI Voice → Record), their
    /// lines read together in one recording and cut apart, so Google's
    /// daily limit, which counts requests, goes further. Cards leave the
    /// queue once done, or once they can't be.
    private func workThroughQueue(plan: Plan, total: Int, cardsTogether: Int, maxCharacters: Int) async -> Phase {
        let sides = CardVoiceSides()
        var done = 0
        var failed = 0
        var failuresInARow = 0
        while !queue.isEmpty {
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

            // The next few cards still to do, up to `maxCharacters` of
            // speech.
            var group: [(id: CardID, card: VoiceCard)] = []
            var characters = 0
            for cardId in queue {
                guard group.count < cardsTogether else { break }
                // Gone, no words to read, or done already: nothing to do.
                guard let html = await sides.sides(of: cardId) else {
                    queue.removeAll { $0 == cardId }
                    continue
                }
                let card = VoiceCard(front: html.front, back: html.back, deckName: "")
                if card.written.question.isEmpty || recorder.isReady(card, voice: plan.voice, rewrites: plan.rewrites) {
                    queue.removeAll { $0 == cardId }
                    done += 1
                    continue
                }
                let size = card.question.count + card.answer.count
                if !group.isEmpty, characters + size > maxCharacters { break }
                group.append((id: cardId, card: card))
                characters += size
            }
            phase = .preparing(done: done, of: total)
            guard !group.isEmpty else { continue }

            let cards = group.map { $0.card }
            var outcomes = await recorder.make(cards, voice: plan.voice, rewrites: plan.rewrites)
            // Google asked for a pause: wait out the minute, then try the
            // rest again.
            var waits = 0
            while outcomes.contains(.notDone), waits < 5, let pause = AIVoiceRecorder.pause, !pause.daily, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(1, pause.until.timeIntervalSinceNow)))
                outcomes = await recorder.make(cards, voice: plan.voice, rewrites: plan.rewrites)
                waits += 1
            }

            for (entry, outcome) in zip(group, outcomes) {
                switch outcome {
                case .ready:
                    queue.removeAll { $0 == entry.id }
                    done += 1
                    failuresInARow = 0
                case .failed:
                    queue.removeAll { $0 == entry.id }
                    failed += 1
                    failuresInARow += 1
                case .notDone:
                    break
                }
            }
            phase = .preparing(done: done, of: total)

            if outcomes.contains(.notDone) {
                // The cards not done stay first in line.
                if case .notInBackground? = recorder.lastError as? SpokenCheck.Failure {
                    CardVoiceLog.shared.add("Waiting for Amgi to be open to check the recordings: \(queue.count) cards still queued", .waiting)
                    return .waiting(queued: queue.count, why: .needsAmgiOpen)
                }
                if Task.isCancelled {
                    CardVoiceLog.shared.add("Stopped, with \(queue.count) cards still queued")
                    return .waiting(queued: queue.count, why: .stopped)
                }
                if let wait = Self.dailyLimitWait {
                    CardVoiceLog.shared.add("Waiting for Google’s daily limit to pass: \(queue.count) cards still queued", .waiting)
                    return .waiting(queued: queue.count, why: wait)
                }
                if recorder.lastError is URLError {
                    CardVoiceLog.shared.add("The connection dropped: \(queue.count) cards still queued", .waiting)
                    return .waiting(queued: queue.count, why: .noConnection)
                }
                if case .noKey? = recorder.lastError as? CardVoiceError {
                    return .waiting(queued: queue.count, why: .noKey)
                }
                return .waiting(queued: queue.count, why: .problems(recorder.problem ?? ""))
            }
            if failuresInARow >= 3 {
                CardVoiceLog.shared.add("Stopped after three cards in a row couldn’t be done", .problem)
                return .waiting(queued: queue.count, why: .problems(recorder.problem ?? ""))
            }
        }
        return finished(done: done, failed: failed)
    }
}

/// Settings → Review → AI Voice → Test Recording Together: ten cards due
/// soon, five read in one recording and five with both sides in one
/// recording each, cut apart and checked like Prepare Cards does, but kept
/// apart from the AI voice's own recordings, to hear beside the ones made
/// a side at a time before choosing how Prepare Cards records. Six
/// recordings in all, of Google's daily hundred or so.
@MainActor
@Observable
public final class CardVoiceTogetherTest {
    public static let shared = CardVoiceTogetherTest()

    public enum Phase: Equatable, Sendable {
        case idle
        case running(String)
        case finished
        case failed(String)
    }

    /// One side of a card, as it came out.
    public struct Line: Identifiable, Equatable, Sendable {
        public let id: Int
        /// "Question" or "Answer".
        public let side: String
        public let text: String
        /// Its piece of the recording made together, when it passed.
        public let piece: URL?
        /// Why it didn't.
        public let problem: String?
        /// The recording of it made on its own before, when there is one.
        public let original: URL?
    }

    /// One recording of several lines.
    public struct Group: Identifiable, Equatable, Sendable {
        public let id: Int
        public let title: String
        public let lines: [Line]
        /// How long Gemini took to record it, in seconds.
        public let seconds: Double?
        /// Why it couldn't be made, or checked, at all.
        public let problem: String?
    }

    public private(set) var phase: Phase = .idle
    public private(set) var groups: [Group] = []

    /// Cards tried: the first half in one recording, the rest a card to a
    /// recording.
    public static let cardCount = 10
    static let togetherCount = 5

    /// The pieces that passed, of all the sides tried.
    public var passed: Int { groups.flatMap(\.lines).filter { $0.piece != nil }.count }
    public var total: Int { groups.flatMap(\.lines).count }
    /// Recordings asked of Gemini, against a side at a time's `total`.
    public var recordings: Int { groups.count }

    public var isRunning: Bool {
        switch phase {
        case .running: true
        case .idle, .finished, .failed: false
        }
    }

    @ObservationIgnored private var work: Task<Void, Never>?

    private init() {}

    public func start() {
        guard !isRunning else { return }
        groups = []
        phase = .running("Getting ready…")
        let voice = ReviewPreferences.aiVoice.rawValue
        let rewrites = ReviewPreferences.aiVoiceRewrites
        work = Task {
            ScreenAwake.keep(.testing)
            await run(voice: voice, rewrites: rewrites)
            ScreenAwake.keep(.testing, false)
            work = nil
        }
    }

    public func stop() {
        work?.cancel()
    }

    /// Asks, the first time, to use the iPhone's speech recognition, which
    /// checks each piece; whether it can.
    public static func allowChecking() async -> Bool {
        guard await SpokenCheck.requestPermission() else { return false }
        return SpokenCheck.isAvailable
    }

    private func run(voice: String, rewrites: Bool) async {
        let recorder = AIVoiceRecorder()
        guard recorder.hasKey else {
            phase = .failed(CardVoiceError.noKey.localizedDescription)
            return
        }
        phase = .running("Asking to use speech recognition…")
        guard await SpokenCheck.requestPermission(), SpokenCheck.isAvailable else {
            phase = .failed("The test needs the iPhone’s own speech recognition to check each piece, and it isn’t allowed or isn’t on this iPhone. Allow it in the Settings app → Amgi → Speech Recognition.")
            return
        }
        if AIVoiceRecorder.isPaused {
            phase = .failed(AIVoiceRecorder.pause?.reason ?? "Google’s limit for the key is reached.")
            return
        }
        CardVoiceRecordings.clearTestFolder()
        CardVoiceLog.shared.add("Testing recording together: finding \(Self.cardCount) cards due soon")

        phase = .running("Finding \(Self.cardCount) cards due soon…")
        let cards = await cardsToTry(voice: voice, rewrites: rewrites, recorder: recorder)
        guard cards.count >= 2 else {
            phase = .failed("There aren’t enough cards with words to read.")
            return
        }

        var scripted: [(card: VoiceCard, lines: CardScript.Lines)] = []
        for card in cards {
            guard !Task.isCancelled else { return stopped() }
            phase = .running("Writing the scripts… \(scripted.count + 1) of \(cards.count)")
            do {
                let lines = try await recorder.script(for: card, rewrites: rewrites)
                scripted.append((card: card, lines: lines))
            } catch {
                if AIVoiceRecorder.stops(error) {
                    phase = .failed(error.localizedDescription)
                    return
                }
            }
        }

        let together = Array(scripted.prefix(Self.togetherCount))
        guard await record(together, title: "\(together.count) cards in one recording", recorder: recorder, voice: voice) else {
            return
        }
        for (offset, entry) in scripted.dropFirst(Self.togetherCount).enumerated() {
            guard !Task.isCancelled else { return stopped() }
            let number = Self.togetherCount + offset + 1
            guard await record([entry], title: "Card \(number): both sides in one recording", recorder: recorder, voice: voice) else {
                return
            }
        }
        phase = .finished
        CardVoiceLog.shared.add("Testing recording together: \(passed) of \(total) sides passed the check, in \(recordings) recordings", .done)
    }

    /// Records the cards' sides together into the test's own folder, and
    /// adds how it went; false when the test can't go on.
    private func record(
        _ entries: [(card: VoiceCard, lines: CardScript.Lines)],
        title: String,
        recorder: AIVoiceRecorder,
        voice: String
    ) async -> Bool {
        var sides: [(side: String, text: String)] = []
        var lines: [String] = []
        for entry in entries {
            for (side, text) in [("Question", entry.lines.question), ("Answer", entry.lines.answer)] where !text.isEmpty {
                sides.append((side: side, text: text))
                if !lines.contains(text) { lines.append(text) }
            }
        }
        guard lines.count > 1 else { return true }
        phase = .running("Recording \(title.prefix(1).lowercased() + title.dropFirst())…")
        CardVoiceLog.shared.add("Testing recording together: \(title)")
        do {
            let outcome = try await recorder.recordTogether(lines, voice: voice, into: CardVoiceRecordings.testFolder)
            groups.append(Group(
                id: groups.count,
                title: title,
                lines: sides.enumerated().map { index, side in
                    Line(
                        id: index,
                        side: side.side,
                        text: side.text,
                        piece: outcome.saved[side.text],
                        problem: outcome.failed[side.text],
                        original: CardVoiceRecordings.recording(of: side.text, voice: voice)
                    )
                },
                seconds: outcome.seconds,
                problem: nil
            ))
            return true
        } catch {
            groups.append(Group(
                id: groups.count,
                title: title,
                lines: sides.enumerated().map { index, side in
                    Line(
                        id: index,
                        side: side.side,
                        text: side.text,
                        piece: nil,
                        problem: nil,
                        original: CardVoiceRecordings.recording(of: side.text, voice: voice)
                    )
                },
                seconds: nil,
                problem: error.localizedDescription
            ))
            if AIVoiceRecorder.stops(error) || error is CancellationError {
                phase = .failed(error.localizedDescription)
                return false
            }
            return true
        }
    }

    /// Cards due soonest, those already recorded a side at a time first,
    /// so there's something to hear the pieces beside.
    private func cardsToTry(voice: String, rewrites: Bool, recorder: AIVoiceRecorder) async -> [VoiceCard] {
        let sides = CardVoiceSides()
        let newPerDay = TodaySnapshotStore.read()?.newTotal ?? 20
        guard let ids = try? await sides.cardIdsByDueDate(newPerDay: newPerDay, days: 7) else { return [] }
        var recorded: [VoiceCard] = []
        var others: [VoiceCard] = []
        for cardId in ids.prefix(300) {
            if Task.isCancelled || recorded.count >= Self.cardCount { break }
            guard let html = await sides.sides(of: cardId) else { continue }
            let card = VoiceCard(front: html.front, back: html.back, deckName: "")
            guard !card.written.question.isEmpty else { continue }
            if recorder.isReady(card, voice: voice, rewrites: rewrites) {
                recorded.append(card)
            } else if others.count < Self.cardCount {
                others.append(card)
            }
        }
        return Array((recorded + others).prefix(Self.cardCount))
    }

    private func stopped() {
        phase = groups.isEmpty ? .failed("Stopped.") : .finished
    }
}

/// A background task iOS lends, to hand between threads: iOS says it's
/// safe to use from any of them.
final class BackgroundTaskBox: @unchecked Sendable {
    let task: BGTask

    init(_ task: BGTask) {
        self.task = task
    }
}

/// The AI voice's work while Amgi isn't on screen, by two means iOS has.
///
/// Overnight: a processing task iOS runs when it suits, usually with the
/// iPhone charging and on a network, asked for whenever there's work. It
/// finds new cards and works through the queue until iOS wants the time
/// back.
///
/// On iOS 26, work started in Amgi carries on once it's left: a
/// continued-processing task, whose progress iOS shows, and which it ends
/// if it stops moving. Each run has an identifier of its own, under the
/// bundle's, registered just before it's asked for, as Apple advises.
enum CardVoiceBackground {
    private static var bundle: String {
        Bundle.main.bundleIdentifier ?? "com.amgiapp.AmgiApp"
    }

    static var overnightIdentifier: String { bundle + ".voice-overnight" }

    /// At launch, before it ends, as iOS requires.
    static func register() {
        _ = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: overnightIdentifier,
            using: nil,
            launchHandler: overnightHandler()
        )
    }

    /// Asks for time overnight: replaces any request already made.
    static func scheduleOvernight() {
        let request = BGProcessingTaskRequest(identifier: overnightIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.review.error("Couldn't ask for time overnight: \(error.localizedDescription)")
        }
    }

    @available(iOS 26.0, *)
    static func submitContinued(cards: Int) {
        let identifier = bundle + ".voice." + UUID().uuidString
        guard BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil, launchHandler: continuedHandler()) else {
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Preparing the AI voice",
            subtitle: "\(cards) \(cards == 1 ? "card" : "cards")"
        )
        // Now or not at all: the work runs anyway while Amgi is open.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.review.error("Couldn't carry on in the background: \(error.localizedDescription)")
        }
    }

    /// How far the work has got, for iOS to show: a hundred units a card,
    /// and `ticks` of the next while it's under way.
    static func report(_ box: BackgroundTaskBox, done: Int, of total: Int, ticks: Int64) {
        guard #available(iOS 26.0, *), let task = box.task as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = Int64(max(total, 1)) * 100
        task.progress.completedUnitCount = min(Int64(done) * 100 + ticks, task.progress.totalUnitCount)
        task.updateTitle("Preparing the AI voice", subtitle: "\(done) of \(total) cards")
    }

    /// When iOS wants its time back: the work stops after the card under
    /// way, and the rest stay queued.
    nonisolated static func stopping() -> @Sendable () -> Void {
        {
            Task { @MainActor in CardVoicePreparation.shared.stop() }
        }
    }

    nonisolated private static func overnightHandler() -> @Sendable (BGTask) -> Void {
        { task in
            let box = BackgroundTaskBox(task)
            Task { @MainActor in await CardVoicePreparation.shared.workOvernight(box) }
        }
    }

    nonisolated private static func continuedHandler() -> @Sendable (BGTask) -> Void {
        { task in
            let box = BackgroundTaskBox(task)
            Task { @MainActor in CardVoicePreparation.shared.continuedStarted(box) }
        }
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
        case testing
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
