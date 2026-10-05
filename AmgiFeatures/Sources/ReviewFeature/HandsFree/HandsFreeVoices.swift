//
//  HandsFreeVoices.swift
//  ReviewFeature
//

import AVFoundation
import Foundation

/// One of the iPhone's voices, as Settings offers it.
public struct HandsFreeVoiceChoice: Identifiable, Hashable, Sendable {
    /// The voice's identifier, which is what's stored.
    public let id: String
    public let title: String
}

/// The iPhone's own voices for reading cards aloud, at no cost. The basic
/// ones sound robotic; the Enhanced and Premium ones, a free download in
/// the Settings app (Accessibility → Read & Speak → Voices), sound far more
/// natural, and are used by themselves once they're there.
public enum HandsFreeVoices {
    /// The voices installed for the phone's language, best first.
    public static func choices() -> [HandsFreeVoiceChoice] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        return ranked(for: language).map { voice in
            HandsFreeVoiceChoice(id: voice.identifier, title: title(of: voice, phoneLanguage: language))
        }
    }

    /// The best voice installed for `language` ("en-US"): Premium, then
    /// Enhanced, then basic, the language's own region first.
    static func best(for language: String) -> AVSpeechSynthesisVoice? {
        ranked(for: language).first
    }

    static func ranked(for language: String) -> [AVSpeechSynthesisVoice] {
        let base = languageCode(of: language)
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { languageCode(of: $0.language) == base && isForReading($0) }
            .sorted { first, second in
                if first.quality != second.quality {
                    return first.quality.rawValue > second.quality.rawValue
                }
                let firstIsHere = first.language == language
                if firstIsHere != (second.language == language) { return firstIsHere }
                return first.name < second.name
            }
    }

    /// Not the novelty voices (Bells, Zarvox…), a Personal Voice, or the
    /// old Eloquence ones (Eddy, Flo, Grandma…): none is for reading cards.
    static func isForReading(_ voice: AVSpeechSynthesisVoice) -> Bool {
        !voice.voiceTraits.contains(.isNoveltyVoice)
            && !voice.voiceTraits.contains(.isPersonalVoice)
            && !voice.identifier.contains("eloquence")
    }

    /// "en" for "en-US".
    static func languageCode(of language: String) -> String {
        String(language.prefix { $0 != "-" && $0 != "_" })
    }

    /// "Ava (Premium)", "Daniel (Enhanced, United Kingdom)", "Samantha".
    static func title(of voice: AVSpeechSynthesisVoice, phoneLanguage: String) -> String {
        // Some names carry their quality already, as "Ava (Premium)".
        let name = voice.name.components(separatedBy: " (").first ?? voice.name
        var details: [String] = []
        switch voice.quality {
        case .premium: details.append("Premium")
        case .enhanced: details.append("Enhanced")
        default: break
        }
        if voice.language != phoneLanguage,
           let region = voice.language.split(separator: "-").last,
           let regionName = Locale.current.localizedString(forRegionCode: String(region)) {
            details.append(regionName)
        }
        return details.isEmpty ? name : "\(name) (\(details.joined(separator: ", ")))"
    }
}
