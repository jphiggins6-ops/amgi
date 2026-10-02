//
//  ReviewPace.swift
//  ReviewCore
//

public import AnkiKit
public import Foundation

/// How quickly cards are being answered in this session, and how often
/// they're missed: enough to guess how long the rest of it will take.
public struct ReviewPace: Equatable, Sendable {
    /// A card left on screen while the phone is put down would otherwise
    /// stretch every later estimate. Anki stops counting an answer's time at
    /// a minute too (its "Maximum answer seconds" default).
    static let longestCountedAnswerMs = 60_000
    /// Fewer answers than this don't make a pace worth showing.
    static let answersBeforeEstimating = 3

    private struct Answer: Equatable, Sendable {
        let milliseconds: Int
        let missed: Bool
    }

    private var answers: [Answer] = []

    public init() {}

    public var answerCount: Int { answers.count }

    mutating func record(milliseconds: Int, missed: Bool) {
        answers.append(Answer(
            milliseconds: min(max(milliseconds, 0), Self.longestCountedAnswerMs),
            missed: missed
        ))
    }

    /// Takes back the latest answer, after an undo.
    mutating func removeLast() {
        if !answers.isEmpty { answers.removeLast() }
    }

    /// Roughly how many seconds the cards in `counts` will take at this
    /// pace, or nil until a few answers have set one.
    ///
    /// Every card left takes an answer, and a new card at least one more
    /// for its learning step. A miss brings a card back, and so can the
    /// answer after it, at this session's miss rate. Early on a few answers
    /// say little about that rate, so it starts out leaning on one miss in
    /// ten.
    public func secondsLeft(for counts: DeckCounts) -> Double? {
        guard let averageSeconds else { return nil }
        let count = Double(answers.count)
        let misses = Double(answers.filter(\.missed).count)
        let missRate = min((misses + 0.5) / (count + 5), 0.5)
        let answersLeft = Double(max(counts.total + counts.newCount, 0)) / (1 - missRate)
        return answersLeft * averageSeconds
    }

    /// Roughly how many seconds `answersLeft` more answers will take at
    /// this pace, for a session that shows each card once and so knows
    /// exactly how many are left.
    public func secondsLeft(forAnswers answersLeft: Int) -> Double? {
        guard let averageSeconds else { return nil }
        return Double(max(answersLeft, 0)) * averageSeconds
    }

    private var averageSeconds: Double? {
        guard answers.count >= Self.answersBeforeEstimating else { return nil }
        return Double(answers.reduce(0) { $0 + $1.milliseconds }) / Double(answers.count) / 1000
    }

    /// What the review screen shows, e.g. "About 12 min left · done around
    /// 3:42 PM". `secondsLeft` is nil until there's a pace to go on.
    public static func summary(secondsLeft: Double?, now: Date) -> String {
        guard let secondsLeft else { return "Measuring your pace…" }
        let minutes = Int((secondsLeft / 60).rounded())
        guard minutes >= 1 else { return "Less than a minute left" }
        let finish = now.addingTimeInterval(Double(minutes * 60))
            .formatted(date: .omitted, time: .shortened)
        return "About \(duration(minutes: minutes)) left · done around \(finish)"
    }

    static func duration(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
