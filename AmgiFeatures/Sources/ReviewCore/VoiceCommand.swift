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
    /// Bury the card until tomorrow and go on to the next.
    case bury
    /// Flag the card: 1 red, 2 orange.
    case flag(UInt32)
    /// Leave hands-free mode.
    case stop

    /// The words listened for, so the recognizer favours them.
    public static let vocabulary = [
        "show", "answer", "flip", "again", "hard", "good", "easy", "repeat", "undo", "stop",
        "bury", "red flag", "orange flag", "flag red", "flag orange",
    ]

    /// The last command in what was heard: later words win, so "hmm…
    /// good" is Good. Nil when nothing in it is a command.
    public static func lastCommand(in transcript: String) -> VoiceCommand? {
        let words = transcript.lowercased().split { !$0.isLetter }.map(String.init)
        for index in words.indices.reversed() {
            if let command = command(at: index, in: words) { return command }
        }
        return nil
    }

    /// The command at `words[index]`. A flag's colour goes either side of
    /// "flag" ("red flag", "flag orange"); "flag" alone is red, as in Anki,
    /// and a colour alone is nothing.
    static func command(at index: Int, in words: [String]) -> VoiceCommand? {
        let word = words[index]
        let before = index > 0 ? words[index - 1] : nil
        let after = index + 1 < words.count ? words[index + 1] : nil
        if flagWords.contains(word) {
            return .flag(flagColour(before) ?? flagColour(after) ?? 1)
        }
        if let colour = flagColour(word) {
            let besideFlag = [before, after].contains { neighbour in neighbour.map { flagWords.contains($0) } ?? false }
            return besideFlag ? .flag(colour) : nil
        }
        return command(for: word)
    }

    /// One word's command. Close alternatives are taken too, and the words
    /// speech recognition often hears in their place ("heart" for hard),
    /// but nothing as common as "yes", "no" or "so", which a passer-by
    /// could say.
    static func command(for word: String) -> VoiceCommand? {
        switch word {
        case "show", "shows", "shown", "answer", "answers", "flip", "flipped", "flips", "reveal": .reveal
        case "again", "gain", "agin", "forgot", "fail": .rate(.again)
        case "hard", "heart", "hearts", "hart", "harder", "difficult": .rate(.hard)
        case "good", "goods", "gud", "correct": .rate(.good)
        case "easy", "eazy", "easier", "easey": .rate(.easy)
        case "repeat", "repeats", "repeated", "replay", "pardon": .repeatSide
        case "undo", "undue", "undid": .undo
        case "bury", "berry", "burry", "barry", "buried", "berries": .bury
        case "stop", "pause", "quit", "exit": .stop
        default: nil
        }
    }

    private static let flagWords: Set<String> = ["flag", "flags", "flagged", "flack", "flak"]

    private static func flagColour(_ word: String?) -> UInt32? {
        switch word ?? "" {
        case "red", "read", "rad": 1
        case "orange", "oranges": 2
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
        case .bury: "bury"
        case .flag(1): "red flag"
        case .flag(2): "orange flag"
        case .flag: "flag"
        case .stop: "stop"
        }
    }
}
