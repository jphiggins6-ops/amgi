//
//  SpokenCardText.swift
//  ReviewCore
//

public import Foundation

/// What hands-free mode reads aloud: a rendered card side as speakable
/// text, split into runs by writing system so each can go to a voice that
/// speaks it.
public enum SpokenCardText {
    public enum Script: Equatable, Sendable {
        /// Latin and anything else: read in the phone's own language.
        case other
        case hangul
        case japanese
        case chinese
    }

    public struct Segment: Equatable, Sendable {
        public let text: String
        public let script: Script

        public init(text: String, script: Script) {
            self.text = text
            self.script = script
        }
    }

    // MARK: - Sides

    /// The question side, read as it shows. A cloze blank is read "blank".
    public static func question(fromHTML html: String) -> String {
        spoken(readable(html))
    }

    /// Just the answer, not the card again. On a cloze card that's the
    /// revealed cloze, or clozes, alone; otherwise what's below Anki's
    /// `<hr id=answer>`, or the whole side without that line. The Extra
    /// field (from `ExtraFieldMarker` on) is never read.
    public static func answer(fromHTML html: String) -> String {
        var side = html
        if let extra = side.range(of: ExtraFieldMarker.html) {
            side = String(side[..<extra.lowerBound])
        }
        let clozes = revealedClozes(in: side)
        if !clozes.isEmpty {
            return spoken(clozes.map(readable).filter { !$0.isEmpty }.joined(separator: " "))
        }
        let range = NSRange(side.startIndex..., in: side)
        if let match = answerDivider.firstMatch(in: side, range: range),
           let divider = Range(match.range, in: side) {
            return spoken(readable(String(side[divider.upperBound...])))
        }
        return spoken(readable(side))
    }

    /// The inner HTML of each answered cloze (`<span class="cloze">`), in
    /// order. Spans nested inside one are counted, so it ends at its own
    /// closing tag.
    static func revealedClozes(in html: String) -> [String] {
        var clozes: [String] = []
        var searchFrom = html.startIndex
        while let open = html.range(of: #"class="cloze""#, range: searchFrom..<html.endIndex),
              let tagEnd = html.range(of: ">", range: open.upperBound..<html.endIndex) {
            var depth = 1
            var cursor = tagEnd.upperBound
            var end: String.Index?
            while depth > 0 {
                let nextOpen = html.range(of: "<span", options: .caseInsensitive, range: cursor..<html.endIndex)
                guard let nextClose = html.range(of: "</span>", options: .caseInsensitive, range: cursor..<html.endIndex) else { break }
                if let nextOpen, nextOpen.lowerBound < nextClose.lowerBound {
                    depth += 1
                    cursor = nextOpen.upperBound
                } else {
                    depth -= 1
                    cursor = nextClose.upperBound
                    if depth == 0 { end = nextClose.lowerBound }
                }
            }
            guard let end else { break }
            clozes.append(String(html[tagEnd.upperBound..<end]))
            searchFrom = cursor
        }
        return clozes
    }

    /// A rendered side as text to speak. Anything the card doesn't show is
    /// left out: hidden elements (a hint's content until it's tapped),
    /// scripts, styles, icons and buttons. Pictures and sounds are skipped,
    /// and each line ends in a stop, so the voice pauses between lines.
    public static func readable(_ html: String) -> String {
        var text = replacing(comments, in: html, with: " ")
        text = withoutHiddenElements(text)
        text = replacing(clozeBlank, in: text, with: " blank ")
        text = replacing(soundTag, in: text, with: " ")
        text = replacing(mathDelimiter, in: text, with: " ")
        text = replacing(lineBreak, in: text, with: "\n")
        text = replacing(power, in: text, with: "^$1")
        text = replacing(raisedOrLowered, in: text, with: "")
        text = replacing(anyTag, in: text, with: " ")
        text = replacing(numericEntity, in: text) { groups in
            let code = groups[1].flatMap { UInt32($0) } ?? groups[2].flatMap { UInt32($0, radix: 16) }
            return code.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? " "
        }
        // &amp; last, or "&amp;lt;" would decode twice.
        for (entity, character) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&hellip;", "…"),
            ("&quot;", "\""), ("&#39;", "'"),
            ("&rarr;", "→"), ("&rArr;", "⇒"), ("&uarr;", "↑"), ("&darr;", "↓"),
            ("&ge;", "≥"), ("&le;", "≤"), ("&ne;", "≠"), ("&asymp;", "≈"), ("&plusmn;", "±"),
            ("&times;", "×"), ("&deg;", "°"), ("&micro;", "\u{00B5}"),
            ("&ndash;", "–"), ("&mdash;", "—"), ("&lsquo;", "'"), ("&rsquo;", "'"),
            ("&ldquo;", "\""), ("&rdquo;", "\""),
            ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return lines
            .map { line in line.last.map(sentenceEnds.contains) == true ? line : line + "." }
            .joined(separator: " ")
    }

    // MARK: - Said as a person says it

    /// `text` with the shorthand a voice would spell out, or read as a
    /// symbol's name, put the way a person says it: "↑ HR → ↓ CO" as
    /// "increased HR leads to decreased CO", "5 mg/kg q6h" as "5 milligrams
    /// per kilogram every 6 hours", "Tx" as "treatment". Only the usual
    /// shorthand of medical cards, as whole words in its usual case, so
    /// anything else is read as it's written.
    public static func spoken(_ text: String) -> String {
        var text = withPlainDigits(text)
        for (pattern, saying) in sayings {
            text = replacing(pattern, in: text, with: saying)
        }
        text = replacing(measurement, in: text) { groups in
            let number = groups[1] ?? ""
            let symbol = groups[2] ?? ""
            let unit = unitNames[symbol] ?? (one: symbol, many: symbol)
            let per = (groups[3] ?? "")
                .split(separator: "/")
                .compactMap { perUnitNames[$0.trimmingCharacters(in: .whitespaces)] }
                .map { " per " + $0 }
                .joined()
            return number + " " + (number == "1" ? unit.one : unit.many) + per
        }
        text = replacing(perUnitAfterWord, in: text) { groups in
            let symbol = groups[1] ?? ""
            return " per " + (perUnitNames[symbol] ?? symbol)
        }
        text = replacing(perBeforeNumber, in: text, with: " per ")
        text = replacing(spaceBeforePunctuation, in: text, with: "$1")
        return text.split(separator: " ").joined(separator: " ")
    }

    /// Superscript and subscript digits as plain ones, with a power marked
    /// "^": "10⁹" as "10^9", "Ca²⁺" as "Ca2+", "CO₂" as "CO2".
    static func withPlainDigits(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text {
            if let plain = superscripts[character] {
                // Only after a plain digit: "Ca²⁺" and "HCO₃⁻" are no powers.
                if let previous, previous.isASCII, previous.isWholeNumber, plain != "+" {
                    result.append("^")
                }
                result.append(plain)
            } else if let plain = subscripts[character] {
                result.append(plain)
            } else {
                result.append(character)
            }
            previous = character
        }
        return result
    }

    private static let superscripts: [Character: Character] = [
        "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4",
        "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9", "⁺": "+", "⁻": "-",
    ]
    private static let subscripts: [Character: Character] = [
        "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4",
        "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9", "₊": "+", "₋": "-",
    ]

    /// What each piece of shorthand is said as, in this order: ions first,
    /// so "HCO3- 22-28" isn't taken for a range; then arrows and signs,
    /// shorthand, ranges. Measurements come after, in `spoken`.
    private static let sayingPatterns: [(pattern: String, saying: String)] = [
        // Ions, as they're said.
        (#"\bNa\+\s*/\s*K\+"#, "sodium-potassium"),
        (#"\bNa\+"#, "sodium"),
        (#"\bK\+"#, "potassium"),
        (#"\bCa(?:2\+|\+\+)"#, "calcium"),
        (#"\bMg(?:2\+|\+\+)"#, "magnesium"),
        (#"\bFe(?:3\+|\+\+\+)"#, "ferric iron"),
        (#"\bFe(?:2\+|\+\+)"#, "ferrous iron"),
        (#"\bNH4\+"#, "ammonium"),
        (#"\bHCO3[-−]?(?!\w)"#, "bicarbonate"),
        (#"\bPO4(?:\^?3[-−])?(?!\w)"#, "phosphate"),
        (#"\bSO4(?:\^?2[-−])?(?!\w)"#, "sulfate"),
        (#"\bCl[-−](?=\s|$|[.,;:)])"#, "chloride"),

        // Arrows and signs.
        (#"\s*(?:→|⟶|⇒|⟹|-{1,2}>|={1,2}>)\s*"#, " leads to "),
        (#"\s*↑\s*↑\s*"#, " greatly increased "),
        (#"\s*↓\s*↓\s*"#, " greatly decreased "),
        (#"\s*[↑⬆]\uFE0F?\s*"#, " increased "),
        (#"\s*[↓⬇]\uFE0F?\s*"#, " decreased "),
        (#"\s*≥\s*"#, " at least "),
        (#"\s*≤\s*"#, " at most "),
        (#"\s*≠\s*"#, " not equal to "),
        (#"\s*≈\s*"#, " about "),
        (#"~\s*(?=\d)"#, "about "),
        (#"\s*(?:±|\+/-)\s*"#, " plus or minus "),
        (#"\s*>>\s*"#, " much greater than "),
        (#"\s*<<\s*"#, " much less than "),
        (#"\s*>\s*(?=\d)|\s+>\s+"#, " greater than "),
        (#"\s*<\s*(?=\d)|\s+<\s+"#, " less than "),
        (#"\s*\(\+\)"#, " positive"),
        (#"\s*\([-−]\)"#, " negative"),
        (#"(?<=\d)\s*(?:×|x(?=\s*10\b))\s*(?=\d)"#, " times "),
        (#"(?<=\d)\s*\^\s*(-?\d+)"#, " to the $1"),
        (#"#(?=\d)"#, "number "),
        // Blood pressure, "120 over 80"; not 20/20 vision.
        (#"(?<![\w.])([5-9]\d|[12]\d\d)\s*/\s*(\d{2,3})(?![\w/]|\.\d)"#, "$1 over $2"),

        // Shorthand with a slash or dots.
        (#"(?<![\w/])N/V/D(?![\w/])"#, "nausea, vomiting and diarrhea"),
        (#"(?<![\w/])N/V(?![\w/])"#, "nausea and vomiting"),
        (#"(?<![\w/])w/o(?![\w/])"#, "without"),
        (#"(?<![\w/])w/u(?![\w/])"#, "workup"),
        (#"(?<![\w/])w/\s*"#, "with "),
        (#"(?<![\w/])b/c(?![\w/])"#, "because"),
        (#"(?<![\w/])c/o(?![\w/])"#, "complains of"),
        (#"(?<![\w/])s/p(?![\w/])"#, "status post"),
        (#"(?<![\w/])h/o(?![\w/])"#, "history of"),
        (#"(?<![\w/])r/o(?![\w/])"#, "rule out"),
        (#"(?<![\w/])f/u(?![\w/])"#, "follow-up"),
        (#"(?<![\w/])b/l(?![\w/])"#, "bilateral"),
        (#"(?<!\w)e\.g\.(?!\w)"#, "for example"),
        (#"(?<!\w)i\.e\.(?!\w)"#, "that is"),
        (#"(?<!\w)a\.k\.a\.(?!\w)"#, "also known as"),
        (#"\b(?:aka|AKA)\b"#, "also known as"),
        (#"\bvs\b\.?"#, "versus"),
        (#"\bapprox\.(?!\w)"#, "approximately"),
        (#"\besp\.(?!\w)"#, "especially"),
        (#"\bt(?:1/2|½)(?![\w/])"#, "half-life"),
        (#"\band/or\b"#, "and or"),

        // Dosing and the usual medical shorthand.
        (#"\bq1\s*hr?\b"#, "every hour"),
        (#"\bq(\d+)\s*[-–]\s*(\d+)\s*h(?:rs?)?\b"#, "every $1 to $2 hours"),
        (#"\bq(\d+)\s*h(?:rs?)?\b"#, "every $1 hours"),
        (#"\b(?:qhs|QHS)\b"#, "at bedtime"),
        (#"\b(?:qod|QOD)\b"#, "every other day"),
        (#"\b(?:qd|QD)\b"#, "daily"),
        (#"\b(?:bid|BID)\b"#, "twice a day"),
        (#"\b(?:tid|TID)\b"#, "three times a day"),
        (#"\b(?:qid|QID)\b"#, "four times a day"),
        (#"\b(?:prn|PRN)\b"#, "as needed"),
        (#"(?<![\w.])x\s?1\s?(?:d|day)\b"#, "for 1 day"),
        (#"(?<![\w.])x\s?(\d+)\s?(?:d|days)\b"#, "for $1 days"),
        (#"(?<![\w.])x\s?1\s?(?:wk|week)\b"#, "for 1 week"),
        (#"(?<![\w.])x\s?(\d+)\s?(?:wks?|weeks)\b"#, "for $1 weeks"),
        (#"\bNPO\b"#, "nothing by mouth"),
        (#"\bPO\b"#, "by mouth"),
        (#"\bDDx\b"#, "differential diagnosis"),
        (#"\bDx\b"#, "diagnosis"),
        (#"\b[TR]x\b"#, "treatment"),
        (#"\bSx\b"#, "symptoms"),
        (#"\bPMHx?\b"#, "past medical history"),
        (#"\bFHx\b"#, "family history"),
        (#"\bHx\b"#, "history"),
        (#"\bFx\b"#, "fracture"),
        (#"\bBx\b"#, "biopsy"),
        (#"\bPpx\b"#, "prophylaxis"),
        (#"\b[Aa]bx\b"#, "antibiotics"),
        (#"\bpts\b"#, "patients"),
        (#"\bpt\b"#, "patient"),
        (#"\bPts\b"#, "Patients"),
        (#"\bPt\b"#, "Patient"),
        (#"\bSOB\b"#, "shortness of breath"),
        (#"\bDOE\b"#, "dyspnea on exertion"),
        (#"\bHTN\b"#, "hypertension"),
        (#"\bCXR\b"#, "chest X-ray"),
        (#"\bdz\b"#, "disease"),
        (#"\bfxn\b"#, "function"),

        // Ranges: "4-6" is "4 to 6".
        (#"(?<=\d)\s*[-–—]\s*(?=\d)"#, " to "),
    ]

    private static let sayings: [(NSRegularExpression, String)] = sayingPatterns.map { entry in
        (try! NSRegularExpression(pattern: entry.pattern), entry.saying)
    }

    /// Units after a number, said in full: singular after "1", and "per"
    /// for up to two units after a slash ("mg/kg/day").
    private static let unitNames: [String: (one: String, many: String)] = [
        "mg": ("milligram", "milligrams"),
        "mcg": ("microgram", "micrograms"),
        "\u{00B5}g": ("microgram", "micrograms"),
        "\u{03BC}g": ("microgram", "micrograms"),
        "ng": ("nanogram", "nanograms"),
        "pg": ("picogram", "picograms"),
        "g": ("gram", "grams"),
        "kg": ("kilogram", "kilograms"),
        "mL": ("milliliter", "milliliters"),
        "ml": ("milliliter", "milliliters"),
        "dL": ("deciliter", "deciliters"),
        "L": ("liter", "liters"),
        "\u{00B5}L": ("microliter", "microliters"),
        "\u{03BC}L": ("microliter", "microliters"),
        "mmol": ("millimole", "millimoles"),
        "mEq": ("milliequivalent", "milliequivalents"),
        "mOsm": ("milliosmole", "milliosmoles"),
        "mmHg": ("millimeter of mercury", "millimeters of mercury"),
        "mm Hg": ("millimeter of mercury", "millimeters of mercury"),
        "cmH2O": ("centimeter of water", "centimeters of water"),
        "cm H2O": ("centimeter of water", "centimeters of water"),
        "mm": ("millimeter", "millimeters"),
        "cm": ("centimeter", "centimeters"),
        "m2": ("square meter", "square meters"),
        "nm": ("nanometer", "nanometers"),
        "\u{00B5}m": ("micrometer", "micrometers"),
        "\u{03BC}m": ("micrometer", "micrometers"),
        "IU": ("international unit", "international units"),
        "U": ("unit", "units"),
        "bpm": ("beat per minute", "beats per minute"),
        "kcal": ("kilocalorie", "kilocalories"),
        "mV": ("millivolt", "millivolts"),
        "ms": ("millisecond", "milliseconds"),
        "sec": ("second", "seconds"),
        "min": ("minute", "minutes"),
        "mins": ("minute", "minutes"),
        "h": ("hour", "hours"),
        "hr": ("hour", "hours"),
        "hrs": ("hour", "hours"),
        "wk": ("week", "weeks"),
        "wks": ("week", "weeks"),
        "mo": ("month", "months"),
        "mos": ("month", "months"),
        "yr": ("year", "years"),
        "yrs": ("year", "years"),
        "yo": ("year old", "year old"),
        "y/o": ("year old", "year old"),
        "y.o.": ("year old", "year old"),
        "°C": ("degree Celsius", "degrees Celsius"),
        "°F": ("degree Fahrenheit", "degrees Fahrenheit"),
    ]

    /// What a unit after a slash is said as, after "per".
    private static let perUnitNames: [String: String] = [
        "kg": "kilogram", "g": "gram", "mg": "milligram", "mmol": "millimole",
        "L": "liter", "dL": "deciliter", "mL": "milliliter",
        "\u{00B5}L": "microliter", "\u{03BC}L": "microliter", "uL": "microliter",
        "mm3": "cubic millimeter", "m2": "square meter",
        "min": "minute", "h": "hour", "hr": "hour", "d": "day", "day": "day",
        "wk": "week", "sec": "second", "s": "second", "hpf": "high-power field", "dose": "dose",
    ]

    /// After a word rather than a measurement ("breaths/min", "10^9/L"),
    /// only the units that can't be mistaken for anything else.
    private static let perUnitsAfterWord = [
        "min", "h", "hr", "d", "day", "wk", "kg", "L", "dL", "mL",
        "\u{00B5}L", "\u{03BC}L", "uL", "mm3", "m2", "hpf", "sec",
    ]

    private static let measurement = try! NSRegularExpression(
        pattern: #"(?<![\w.])(\d+(?:[.,]\d+)*)\s?("#
            + alternation(Array(unitNames.keys))
            + #")((?:\s?/\s?(?:"#
            + alternation(Array(perUnitNames.keys))
            + #")){0,2})(?!\w)"#
    )
    private static let perUnitAfterWord = try! NSRegularExpression(
        pattern: #"(?<=[\w)])/("# + alternation(perUnitsAfterWord) + #")(?!\w)"#
    )
    /// "5 milligrams/10 milliliters", once the units are said.
    private static let perBeforeNumber = try! NSRegularExpression(pattern: #"(?<=[a-z])/(?=\d)"#)
    private static let spaceBeforePunctuation = try! NSRegularExpression(pattern: #"\s+([.,;:!?])"#)

    /// The longest first, so "mmHg" is matched before "mm".
    private static func alternation(_ words: [String]) -> String {
        words
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
    }

    // MARK: - Voices

    /// `text` in runs of one writing system, so Korean is read by a Korean
    /// voice and the English beside it by an English one. Spaces, digits
    /// and punctuation join the run they're in. Chinese characters count as
    /// Japanese when the text has kana.
    public static func segments(_ text: String) -> [Segment] {
        let hasKana = text.unicodeScalars.contains { isKana($0.value) }
        var segments: [Segment] = []
        var run = ""
        var runScript: Script?
        for character in text {
            if let script = script(of: character, hasKana: hasKana) {
                if let current = runScript, current != script {
                    segments.append(Segment(text: run, script: current))
                    run = ""
                }
                runScript = script
            }
            run.append(character)
        }
        segments.append(Segment(text: run, script: runScript ?? .other))
        return segments
            .map { Segment(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), script: $0.script) }
            .filter { !$0.text.isEmpty }
    }

    /// Nil for what belongs to no writing system: spaces, digits, marks.
    static func script(of character: Character, hasKana: Bool) -> Script? {
        guard let scalar = character.unicodeScalars.first?.value else { return nil }
        if isHangul(scalar) { return .hangul }
        if isKana(scalar) { return .japanese }
        if isHan(scalar) { return hasKana ? .japanese : .chinese }
        return character.isLetter ? .other : nil
    }

    static func isHangul(_ scalar: UInt32) -> Bool {
        (0xAC00...0xD7A3).contains(scalar) || (0x1100...0x11FF).contains(scalar) || (0x3130...0x318F).contains(scalar)
    }

    static func isKana(_ scalar: UInt32) -> Bool {
        (0x3040...0x30FF).contains(scalar) || (0x31F0...0x31FF).contains(scalar) || (0xFF66...0xFF9F).contains(scalar)
    }

    static func isHan(_ scalar: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(scalar) || (0x3400...0x4DBF).contains(scalar) || (0xF900...0xFAFF).contains(scalar)
    }

    // MARK: - Hidden elements

    /// The HTML with every element the card doesn't show taken out, nested
    /// content and all. A regular expression can't match nested tags, so
    /// this walks them and counts depth.
    static func withoutHiddenElements(_ html: String) -> String {
        let source = html as NSString
        var output = ""
        var cursor = 0
        var skipping: (name: String, depth: Int)?
        for match in tag.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let tagRange = match.range
            if skipping == nil {
                output += source.substring(with: NSRange(location: cursor, length: tagRange.location - cursor))
            }
            cursor = tagRange.location + tagRange.length

            let isClosing = match.range(at: 1).length > 0
            let name = source.substring(with: match.range(at: 2)).lowercased()
            let attributes = source.substring(with: match.range(at: 3))
            let isEmptyElement = voidElements.contains(name) || attributes.hasSuffix("/")

            if let skip = skipping {
                if skip.name == name && !isEmptyElement {
                    let depth = skip.depth + (isClosing ? -1 : 1)
                    if depth == 0 {
                        skipping = nil
                    } else {
                        skipping = (name: name, depth: depth)
                    }
                }
                continue
            }
            if !isClosing && !isEmptyElement && hides(name: name, attributes: attributes) {
                skipping = (name: name, depth: 1)
                continue
            }
            output += source.substring(with: tagRange)
        }
        if skipping == nil, cursor < source.length {
            output += source.substring(from: cursor)
        }
        return output
    }

    static func hides(name: String, attributes: String) -> Bool {
        if notContent.contains(name) { return true }
        let range = NSRange(attributes.startIndex..., in: attributes)
        return hiddenAttributes.firstMatch(in: attributes, range: range) != nil
    }

    private static let notContent: Set<String> = ["script", "style", "svg", "button", "template", "head", "title", "audio", "video"]
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
    ]
    private static let sentenceEnds: Set<Character> = [".", "!", "?", ":", ";", "。", "！", "？", "…"]

    // MARK: - Patterns

    private static let tag = try! NSRegularExpression(pattern: #"<(/?)([a-zA-Z][a-zA-Z0-9-]*)([^>]*)>"#)
    /// `display: none`, the `hidden` attribute, or Anki's hint link
    /// (`class=hint`), which only says what the hidden content is called.
    private static let hiddenAttributes = try! NSRegularExpression(
        pattern: #"display\s*:\s*none|(^|\s)hidden(\s|=|/|$)|class\s*=\s*["']?[^"'>]*\bhint\b"#,
        options: [.caseInsensitive]
    )
    private static let answerDivider = try! NSRegularExpression(
        pattern: #"<hr[^>]*\bid\s*=\s*["']?answer["']?[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let comments = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)
    private static let clozeBlank = try! NSRegularExpression(pattern: #"\[(\.\.\.|…)\]"#)
    private static let soundTag = try! NSRegularExpression(pattern: #"\[sound:[^\]]*\]"#)
    private static let mathDelimiter = try! NSRegularExpression(pattern: #"\\[()\[\]]"#)
    private static let lineBreak = try! NSRegularExpression(
        pattern: #"<br\s*/?>|</(div|p|li|tr|h[1-6])\s*>|<hr\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    /// "10<sup>9</sup>", a power.
    private static let power = try! NSRegularExpression(
        pattern: #"(?<=\d)<sup\b[^>]*>\s*(-?\d+)\s*</sup\s*>"#,
        options: [.caseInsensitive]
    )
    /// Superscript and subscript tags, which join their text to what it's
    /// on: "Ca<sup>2+</sup>" is "Ca2+", "H<sub>2</sub>O" is "H2O".
    private static let raisedOrLowered = try! NSRegularExpression(
        pattern: #"</?(?:sup|sub)\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let anyTag = try! NSRegularExpression(pattern: #"<[^>]*>"#)
    private static let numericEntity = try! NSRegularExpression(pattern: #"&#(?:(\d+)|[xX]([0-9a-fA-F]+));"#)

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    /// Each match replaced by what `saying` makes of its groups: the whole
    /// match first, nil for a group that took no part.
    private static func replacing(
        _ regex: NSRegularExpression,
        in text: String,
        using saying: ([String?]) -> String
    ) -> String {
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range)
            }
            result += saying(groups)
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }
}
