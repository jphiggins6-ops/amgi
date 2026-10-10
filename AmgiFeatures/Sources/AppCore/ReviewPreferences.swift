//
//  ReviewPreferences.swift
//  AppCore
//
//  Created by Vladimir Gusev on 08.08.2026.
//

import AnkiKit
public import Foundation

public enum ReaderThemeMode: String, CaseIterable, Identifiable {
    case system
    case eyeCare
    case sepia
    case custom

    public var id: String { rawValue }
}

public enum ReviewPreferences {
    public enum Keys {
        public static let playAudioInSilentMode = "review_pref_play_audio_in_silent_mode"
        public static let showCorrectnessSymbols = "review_pref_show_correctness_symbols"
        public static let showAnswerButtons = "review_pref_show_answer_buttons"
        public static let cardRenderEngine = "review_pref_card_render_engine"
        public static let templateRenderOverrides = "review_pref_template_render_overrides"
        public static let showRemainingDays = "review_pref_show_remaining_days"
        public static let showNextReviewTime = "review_pref_show_next_review_time"
        public static let openLinksExternally = "review_pref_open_links_externally"
        public static let lookupPopupEnabled = "review_pref_lookup_popup_enabled"
        public static let lookupPopupFrontEnabled = "review_pref_lookup_popup_front_enabled"
        public static let lookupPopupBackEnabled = "review_pref_lookup_popup_back_enabled"
        /// Where a card starts: near the top by default, leaving room for
        /// the answer to run on below. A new key, so the Center that was
        /// the default before doesn't stay stored in its place.
        public static let cardContentAlignment = "review_pref_card_content_alignment_2"
        public static let glassAnswerButtons = "review_pref_glass_answer_buttons"
        public static let autoMatchCardBackground = "review_pref_auto_match_card_background"
        public static let defersRepeats = "review_pref_defers_repeats"
        public static let showTimeLeft = "review_pref_show_time_left"
        public static let problemCardLapses = "review_pref_problem_card_lapses"
        public static let handsFreeSpeed = "review_pref_hands_free_speed"
        public static let handsFreeVoice = "review_pref_hands_free_voice"
        public static let handsFreeKeepsScreenOn = "review_pref_hands_free_keeps_screen_on"
        public static let handsFreeSharperListening = "review_pref_hands_free_sharper_listening"
        public static let handsFreeEchoCancelling = "review_pref_hands_free_echo_cancelling"
        /// The switch that came before `aiVoiceCards`, read to carry over
        /// a choice of no AI voice.
        public static let aiVoiceForNewCards = "review_pref_ai_voice_for_new_cards"
        public static let aiVoiceCards = "review_pref_ai_voice_cards"
        public static let aiVoice = "review_pref_ai_voice_gemini"
        public static let aiVoiceRewrites = "review_pref_ai_voice_rewrites"
        public static let aiVoiceSince = "review_pref_ai_voice_since"
        /// The cards queued for the AI voice, soonest due first, by id.
        public static let aiVoiceQueue = "review_pref_ai_voice_queue"
        public static let aiVoiceTogether = "review_pref_ai_voice_together"
        public static let appIconBadge = "review_pref_app_icon_badge"
        public static let appIconTurnsGreen = "review_pref_app_icon_turns_green"
    }

    public static var handsFreeSpeed: HandsFreeSpeed {
        UserDefaults.standard.string(forKey: Keys.handsFreeSpeed).flatMap(HandsFreeSpeed.init(rawValue:)) ?? .normal
    }

    /// Whether the screen stays on while hands-free mode runs. On unless
    /// switched off in Settings.
    public static var handsFreeKeepsScreenOn: Bool {
        UserDefaults.standard.object(forKey: Keys.handsFreeKeepsScreenOn) as? Bool ?? true
    }

    /// Hands-free commands heard by Apple's servers rather than on the
    /// phone: they catch more, a moment later, and need a connection.
    public static var handsFreeSharperListening: Bool {
        UserDefaults.standard.bool(forKey: Keys.handsFreeSharperListening)
    }

    /// The iPhone's voice processing on the microphone in hands-free mode,
    /// as for calls: the reading taken out of what it hears, so you can
    /// talk over it, and noise kept down. On unless switched off.
    public static var handsFreeEchoCancelling: Bool {
        UserDefaults.standard.object(forKey: Keys.handsFreeEchoCancelling) as? Bool ?? true
    }

    /// The iPhone voice picked for hands-free mode, by identifier; nil for
    /// the best one installed.
    public static var handsFreeVoice: String? {
        let identifier = UserDefaults.standard.string(forKey: Keys.handsFreeVoice) ?? ""
        return identifier.isEmpty ? nil : identifier
    }

    /// Which cards hands-free mode reads in the AI voice: all of them
    /// unless set otherwise in Settings, or none when the switch that came
    /// before this was turned off.
    public static var aiVoiceCards: AIVoiceCards {
        let defaults = UserDefaults.standard
        if let chosen = defaults.string(forKey: Keys.aiVoiceCards).flatMap(AIVoiceCards.init(rawValue:)) {
            return chosen
        }
        return defaults.object(forKey: Keys.aiVoiceForNewCards) as? Bool == false ? .off : .all
    }

    public static var aiVoice: AIVoice {
        UserDefaults.standard.string(forKey: Keys.aiVoice).flatMap(AIVoice.init(rawValue:)) ?? .defaultVoice
    }

    /// Whether a card is rewritten the way a tutor would say it before the
    /// AI voice reads it. On unless switched off in Settings.
    public static var aiVoiceRewrites: Bool {
        UserDefaults.standard.object(forKey: Keys.aiVoiceRewrites) as? Bool ?? true
    }

    /// How Prepare Cards records the AI voice: a side at a time unless
    /// Settings says to record several together.
    public static var aiVoiceTogether: AIVoiceTogether {
        UserDefaults.standard.string(forKey: Keys.aiVoiceTogether).flatMap(AIVoiceTogether.init(rawValue:)) ?? .eachSide
    }

    /// With `AIVoiceCards.added`, cards added from this moment on are read
    /// in the AI voice, and the deck that was there before keeps the
    /// iPhone's, which costs nothing. It's the first launch with the AI
    /// voice (`noteAIVoiceStart`).
    public static var aiVoiceSince: Date {
        noteAIVoiceStart()
        return Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Keys.aiVoiceSince))
    }

    /// Makes `now` the moment the AI voice starts from, unless there is one.
    public static func noteAIVoiceStart(now: Date = Date()) {
        guard UserDefaults.standard.object(forKey: Keys.aiVoiceSince) == nil else { return }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Keys.aiVoiceSince)
    }

    /// What the number on the app icon counts: reviews and new cards
    /// unless changed in Settings.
    public static var appIconBadge: AppIconBadge {
        UserDefaults.standard.string(forKey: Keys.appIconBadge).flatMap(AppIconBadge.init(rawValue:)) ?? .cardsLeft
    }

    /// Whether the icon's stars turn green once today is done. On unless
    /// switched off in Settings.
    public static var appIconTurnsGreen: Bool {
        UserDefaults.standard.object(forKey: Keys.appIconTurnsGreen) as? Bool ?? true
    }

    /// A card forgotten this many times is flagged orange when it's
    /// forgotten again, which sends it to the Graveyard to be fixed. 0 turns
    /// it off.
    public static let defaultProblemCardLapses = 5
    public static let problemCardLapsesChoices = [0, 3, 4, 5, 6, 8, 10]

    public static var problemCardLapses: Int {
        UserDefaults.standard.object(forKey: Keys.problemCardLapses) as? Int ?? defaultProblemCardLapses
    }

    /// Whether a review shows every due card once before bringing back
    /// cards still in (re)learning today. On unless switched off in
    /// Settings; the watch has no toggle and always gets the default.
    public static var defersRepeats: Bool {
        UserDefaults.standard.object(forKey: Keys.defersRepeats) as? Bool ?? true
    }
}

/// Which cards hands-free mode reads in the AI voice.
public enum AIVoiceCards: String, CaseIterable, Identifiable, Sendable {
    case all
    /// Cards added since `ReviewPreferences.aiVoiceSince`.
    case added
    case off

    public var id: String { rawValue }
}

/// How Prepare Cards records the AI voice. Google's daily limit counts
/// requests, however much each one says, so several sides read in one
/// recording, then cut apart and each checked by the phone's speech
/// recognition, go further: about 100 cards a day with both sides of a
/// card together, 400 to 1,600 with 5 to 20 cards together, against 50 a
/// side at a time. Not more than 20: that's five minutes or so of speech
/// already, and the longer a recording, the likelier Gemini is to cut it
/// short or lose its way, and the more one bad recording costs.
public enum AIVoiceTogether: String, CaseIterable, Identifiable, Sendable {
    case eachSide = "side"
    case bothSides = "card"
    case fiveCards = "cards"
    case tenCards = "cards10"
    case twentyCards = "cards20"

    public var id: String { rawValue }

    /// Cards in each recording; 0 for a side at a time.
    public var cards: Int {
        switch self {
        case .eachSide: 0
        case .bothSides: 1
        case .fiveCards: 5
        case .tenCards: 10
        case .twentyCards: 20
        }
    }

    /// The most text read in one recording, in characters: about a minute
    /// and a half of speech for five cards, and so on. A card longer than
    /// that is recorded with fewer others.
    public var maxCharacters: Int {
        switch self {
        case .eachSide: 0
        case .bothSides, .fiveCards: 1_200
        case .tenCards: 2_400
        case .twentyCards: 4_500
        }
    }

    public var title: String {
        switch self {
        case .eachSide: "One side at a time"
        case .bothSides: "Both sides together"
        case .fiveCards: "5 cards together"
        case .tenCards: "10 cards together"
        case .twentyCards: "20 cards together"
        }
    }

    /// Roughly the cards a day that `limit` recordings make: a little
    /// less than all the sides they hold, as a piece that doesn't pass the
    /// check is recorded again on its own.
    public func cardsADay(limit: Int) -> Int {
        switch self {
        case .eachSide: limit / 2
        case .bothSides: limit * 9 / 10
        case .fiveCards: limit * 4
        case .tenCards: limit * 8
        case .twentyCards: limit * 16
        }
    }
}

/// The AI voice hands-free mode reads cards in: one of
/// Google Gemini's 30 voices, each with Google's word for how it sounds.
public enum AIVoice: String, CaseIterable, Identifiable, Sendable {
    case achernar = "Achernar"
    case achird = "Achird"
    case algenib = "Algenib"
    case algieba = "Algieba"
    case alnilam = "Alnilam"
    case aoede = "Aoede"
    case autonoe = "Autonoe"
    case callirrhoe = "Callirrhoe"
    case charon = "Charon"
    case despina = "Despina"
    case enceladus = "Enceladus"
    case erinome = "Erinome"
    case fenrir = "Fenrir"
    case gacrux = "Gacrux"
    case iapetus = "Iapetus"
    case kore = "Kore"
    case laomedeia = "Laomedeia"
    case leda = "Leda"
    case orus = "Orus"
    case puck = "Puck"
    case pulcherrima = "Pulcherrima"
    case rasalgethi = "Rasalgethi"
    case sadachbia = "Sadachbia"
    case sadaltager = "Sadaltager"
    case schedar = "Schedar"
    case sulafat = "Sulafat"
    case umbriel = "Umbriel"
    case vindemiatrix = "Vindemiatrix"
    case zephyr = "Zephyr"
    case zubenelgenubi = "Zubenelgenubi"

    /// Warm, for a tutor reading cards aloud.
    public static let defaultVoice = AIVoice.sulafat

    public var id: String { rawValue }

    /// "Sulafat (warm)".
    public var title: String {
        "\(rawValue) (\(sound))"
    }

    public var sound: String {
        switch self {
        case .achernar: "soft"
        case .achird: "friendly"
        case .algenib: "gravelly"
        case .algieba: "smooth"
        case .alnilam: "firm"
        case .aoede: "breezy"
        case .autonoe: "bright"
        case .callirrhoe: "easy-going"
        case .charon: "informative"
        case .despina: "smooth"
        case .enceladus: "breathy"
        case .erinome: "clear"
        case .fenrir: "excitable"
        case .gacrux: "mature"
        case .iapetus: "clear"
        case .kore: "firm"
        case .laomedeia: "upbeat"
        case .leda: "youthful"
        case .orus: "firm"
        case .puck: "upbeat"
        case .pulcherrima: "forward"
        case .rasalgethi: "informative"
        case .sadachbia: "lively"
        case .sadaltager: "knowledgeable"
        case .schedar: "even"
        case .sulafat: "warm"
        case .umbriel: "easy-going"
        case .vindemiatrix: "gentle"
        case .zephyr: "bright"
        case .zubenelgenubi: "casual"
        }
    }
}

/// How fast hands-free mode reads cards aloud.
public enum HandsFreeSpeed: String, CaseIterable, Identifiable, Sendable {
    case slow, normal, fast

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .slow: "Slow"
        case .normal: "Normal"
        case .fast: "Fast"
        }
    }
}

public enum ReaderPreferences {
    public enum Keys {
        public static let showTab = "reader_pref_show_tab"
        public static let tapLookup = "reader_pref_tap_lookup"
        public static let deckID = "reader_pref_deck_id"
        public static let notetypeID = "reader_pref_notetype_id"
        public static let bookIDField = "reader_pref_book_id_field"
        public static let bookTitleField = "reader_pref_book_title_field"
        public static let bookCoverField = "reader_pref_book_cover_field"
        public static let chapterTitleField = "reader_pref_chapter_title_field"
        public static let chapterOrderField = "reader_pref_chapter_order_field"
        public static let contentField = "reader_pref_content_field"
        public static let languageField = "reader_pref_language_field"
        public static let bookshelfColumns = "reader_pref_bookshelf_columns"
        public static let bookshelfSortMode = "reader_pref_bookshelf_sort_mode"
        public static let verticalLayout = "reader_pref_vertical_layout"
        public static let selectedFont = "reader_pref_selected_font"
        public static let fontSize = "reader_pref_font_size"
        public static let hideFurigana = "reader_pref_hide_furigana"
        public static let horizontalPadding = "reader_pref_horizontal_padding"
        public static let verticalPadding = "reader_pref_vertical_padding"
        public static let avoidPageBreak = "reader_pref_avoid_page_break"
        public static let justifyText = "reader_pref_justify_text"
        public static let layoutAdvanced = "reader_pref_layout_advanced"
        public static let lineHeight = "reader_pref_line_height"
        public static let characterSpacing = "reader_pref_character_spacing"
        public static let showTitle = "reader_pref_show_title"
        public static let showPercentage = "reader_pref_show_percentage"
        public static let showProgressTop = "reader_pref_show_progress_top"
        public static let themeMode = "reader_pref_theme_mode"
        public static let customContentColor = "reader_pref_custom_content_color"
        public static let customBackgroundColor = "reader_pref_custom_background_color"
        public static let customTextColor = "reader_pref_custom_text_color"
        public static let customHintColor = "reader_pref_custom_hint_color"
        public static let popupWidth = "reader_pref_popup_width"
        public static let popupHeight = "reader_pref_popup_height"
        public static let popupFontSize = "reader_pref_popup_font_size"
        public static let popupFrequencyFontSize = "reader_pref_popup_frequency_font_size"
        public static let popupContentFontSize = "reader_pref_popup_content_font_size"
        public static let popupDictionaryNameFontSize = "reader_pref_popup_dictionary_name_font_size"
        public static let popupKanaFontSize = "reader_pref_popup_kana_font_size"
        public static let popupFullWidth = "reader_pref_popup_full_width"
        public static let popupSwipeToDismiss = "reader_pref_popup_swipe_to_dismiss"
        public static let popupCollapseDictionaries = "reader_pref_popup_collapse_dictionaries"
        public static let popupCompactGlossaries = "reader_pref_popup_compact_glossaries"
        public static let popupAudioSourceTemplate = "reader_pref_popup_audio_source_template"
        public static let popupLocalAudioEnabled = "reader_pref_popup_local_audio_enabled"
        public static let popupAudioAutoplay = "reader_pref_popup_audio_autoplay"
        public static let popupAudioPlaybackMode = "reader_pref_popup_audio_playback_mode"
        public static let popupDebugInfoEnabled = "reader_pref_popup_debug_info_enabled"
        public static let dictionaryMaxResults = "reader_pref_dictionary_max_results"
        public static let dictionaryScanLength = "reader_pref_dictionary_scan_length"
        public static let lookupNoteTemplate = "reader_pref_lookup_note_template"
        public static let popupSearchHistory = "reader_pref_popup_search_history"
        public static let popupCollapsedDictionaries = "reader_pref_popup_collapsed_dictionaries"
    }
}

public enum AppearancePreferences {
    public enum Keys {
        public static let appFont = "appFont"
        public static let showProfileInToolbar = "appearance_show_profile_in_toolbar"
    }
}

public enum CodeEditorPreferences {
    public enum Keys {
        public static let fontSize = "codeEditor_fontSize"
        public static let fontFamily = "codeEditor_fontFamily"
    }

    public static let defaultFontSize: Double = 14
    public static let defaultFontFamily = "Menlo"
}

public enum SyncPreferences {
    public enum Keys {
        public static let modeBase = "syncMode"
        public static let syncMediaBase = "sync_pref_sync_media"
        public static let ioTimeoutSecsBase = "sync_pref_io_timeout_secs"
        public static let mediaLastLogBase = "sync_pref_media_last_log"
        public static let mediaLastSyncedAtBase = "sync_pref_media_last_synced_at"
        public static let lastCollectionSyncedAtBase = "sync_pref_collection_last_synced_at"
        public static let needsFullSyncBase = "sync_pref_needs_full_sync"

        public static func modeForCurrentUser() -> String {
            scoped(modeBase)
        }

        public static func syncMediaForCurrentUser() -> String {
            scoped(syncMediaBase)
        }

        public static func ioTimeoutSecsForCurrentUser() -> String {
            scoped(ioTimeoutSecsBase)
        }

        public static func mediaLastLogForCurrentUser() -> String {
            scoped(mediaLastLogBase)
        }

        public static func mediaLastSyncedAtForCurrentUser() -> String {
            scoped(mediaLastSyncedAtBase)
        }

        public static func lastCollectionSyncedAtForCurrentUser() -> String {
            scoped(lastCollectionSyncedAtBase)
        }

        public static func needsFullSyncForCurrentUser() -> String {
            scoped(needsFullSyncBase)
        }
    }

    public enum Mode: String, CaseIterable, Identifiable {
        case official
        case custom
        case local

        public var id: String { rawValue }
    }

    public enum Timeout: Int, CaseIterable, Identifiable {
        case seconds15 = 15
        case seconds30 = 30
        case seconds60 = 60
        case seconds120 = 120

        public static let defaultValue = seconds60.rawValue

        public var id: Int { rawValue }
    }

    public static let officialServerLabel = "AnkiWeb"

    public static func resolvedMode(_ rawValue: String) -> Mode {
        Mode(rawValue: rawValue) ?? .local
    }

    public static func resolvedTimeout(_ rawValue: Int) -> Timeout {
        Timeout(rawValue: rawValue) ?? .seconds60
    }

    public static func recordMediaSyncLog(_ message: String, date: Date = .now) {
        UserDefaults.standard.set(message, forKey: Keys.mediaLastLogForCurrentUser())
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Keys.mediaLastSyncedAtForCurrentUser())
    }
}

private extension SyncPreferences.Keys {
    static func scoped(_ base: String) -> String {
        "\(base)__\(SyncPreferences.currentProfileID())"
    }
}

private extension SyncPreferences {
    static func currentProfileID() -> String {
        let selectedUser = ProfileScope.current()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = selectedUser.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let profile = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return profile.isEmpty ? "default" : profile
    }
}
