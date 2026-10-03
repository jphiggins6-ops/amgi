//
//  VoiceCommand.swift
//  ReviewCore
//

public import AnkiKit

/// A word said in hands-free mode, and what it does.
public enum VoiceCommand: Equatable, Sendable {
    /// Show the answer.
    case reveal
    /// Rate the card. On the question side the answer is read first.
    case rate(Rating)
    /// Read the current side again.
    case repeatSide
    case undo
    /// Leave hands-free mode.
    case stop

    /// The words listened for, so the recognizer favours them.
    public static let vocabulary = [
        "show", "answer", "flip", "again", "hard", "good", "easy", "repeat", "undo", "stop",
    ]

    /// The last command word in what was heard: later words win, so
    /// "hmm… good" is Good. Nil when nothing in it is a command.
    public static func lastCommand(in transcript: String) -> VoiceCommand? {
        let words = transcript.lowercased().split { !$0.isLetter }
        for word in words.reversed() {
            if let command = command(for: String(word)) { return command }
        }
        return nil
    }

    /// One word's command. A few close alternatives are taken too, but
    /// nothing as common as "yes" or "no", which a passer-by could say.
    static func command(for word: String) -> VoiceCommand? {
        switch word {
        case "show", "answer", "flip", "reveal": .reveal
        case "again", "forgot", "fail": .rate(.again)
        case "hard", "difficult": .rate(.hard)
        case "good", "correct": .rate(.good)
        case "easy": .rate(.easy)
        case "repeat", "replay", "pardon": .repeatSide
        case "undo": .undo
        case "stop", "pause", "quit", "exit": .stop
        default: nil
        }
    }

    /// The word as the screen shows it once heard, e.g. "good".
    public var title: String {
        switch self {
        case .reveal: "show"
        case .rate(.again): "again"
        case .rate(.hard): "hard"
        case .rate(.good): "good"
        case .rate(.easy): "easy"
        case .repeatSide: "repeat"
        case .undo: "undo"
        case .stop: "stop"
        }
    }
}
