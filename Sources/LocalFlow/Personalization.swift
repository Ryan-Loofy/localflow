import Foundation

/// How cleanup writes for the app you are dictating into.
enum WritingStyle: String, Codable, CaseIterable {
    /// The original cleanup: punctuation, lists for steps, `backticks` for code.
    case standard
    /// Chat apps: keeps casual wording and leaves off the final period.
    case casual
    /// Email: polished sentences, paragraphs, and a spoken greeting or sign-off on its own line.
    case formal
    /// No cleanup at all: Whisper's text, with the dictionary and snippets applied.
    case raw
    /// A social post such as LinkedIn: short paragraphs, the speaker's own claims and numbers.
    case post
}

struct DictionarySettings: Codable, Equatable {
    /// Words to spell exactly as written: names, products, jargon. Whisper gets them as a hint and cleanup as a rule.
    var words: [String] = []
    /// What Whisper writes → what you want instead, for words a hint does not fix. Whole words, any case.
    var replacements: [String: String] = [:]
    /// A spoken phrase → the text pasted in its place, such as "my calendar link" → a URL.
    var snippets: [String: String] = [:]
}

extension DictionarySettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        words = try c.decodeIfPresent([String].self, forKey: .words) ?? []
        replacements = try c.decodeIfPresent([String: String].self, forKey: .replacements) ?? [:]
        snippets = try c.decodeIfPresent([String: String].self, forKey: .snippets) ?? [:]
    }
}

enum Personalization {
    /// Styles for well-known apps, by bundle identifier. `appStyles` in settings.json overrides any of them.
    static let builtInAppStyles: [String: WritingStyle] = [
        "com.tinyspeck.slackmacgap": .casual,
        "com.apple.MobileSMS": .casual,
        "net.whatsapp.WhatsApp": .casual,
        "com.hnc.Discord": .casual,
        "ru.keepcoder.Telegram": .casual,
        "org.whispersystems.signal-desktop": .casual,
        "com.microsoft.teams2": .casual,
        "com.apple.mail": .formal,
        "com.microsoft.Outlook": .formal,
        "com.superhuman.electron": .formal,
        "com.readdle.SparkDesktop": .formal
    ]

    /// Websites with their own style when you dictate into them in a browser.
    static let builtInSiteStyles: [String: WritingStyle] = [
        "linkedin.com": .post
    ]

    /// A site rule wins over the browser's app rule; otherwise the app decides.
    static func style(forApp bundleID: String?, host: String?, settings: AppSettings) -> WritingStyle {
        if let host = host?.lowercased() {
            let rules = builtInSiteStyles.mapValues(\.rawValue).merging(settings.siteStyles) { _, mine in mine }
            for (site, name) in rules where host == site.lowercased() || host.hasSuffix("." + site.lowercased()) {
                if let style = WritingStyle(rawValue: name.lowercased()) { return style }
            }
        }
        return style(forApp: bundleID, settings: settings)
    }

    static func style(forApp bundleID: String?, settings: AppSettings) -> WritingStyle {
        guard let bundleID else { return settings.defaultStyle }
        if let name = settings.appStyles[bundleID] {
            return WritingStyle(rawValue: name.lowercased()) ?? settings.defaultStyle
        }
        return builtInAppStyles[bundleID] ?? settings.defaultStyle
    }

    /// Whisper reads about 224 tokens of prompt; past that the start is dropped. 600 characters stays well inside it.
    static let whisperPromptCharacterLimit = 600

    /// The words, comma-separated, as Whisper's prompt. Nil when there are none.
    static func whisperPrompt(_ dictionary: DictionarySettings) -> String? {
        var prompt = ""
        for word in spellings(dictionary) {
            let next = prompt.isEmpty ? word : prompt + ", " + word
            if next.count > whisperPromptCharacterLimit { break }
            prompt = next
        }
        return prompt.isEmpty ? nil : prompt
    }

    /// Every spelling cleanup must keep: the words, then the replacement targets.
    static func spellings(_ dictionary: DictionarySettings) -> [String] {
        var seen = Set<String>()
        return (dictionary.words + dictionary.replacements.keys.sorted().compactMap { dictionary.replacements[$0] })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Replaces each heard phrase with its spelling, whole words only and in any case.
    static func applyReplacements(_ text: String, _ replacements: [String: String]) -> String {
        replacePhrases(in: text, replacements)
    }

    /// The snippet when the whole dictation is just its trigger phrase ("My calendar link."), else nil.
    static func wholeSnippet(_ transcript: String, _ snippets: [String: String]) -> String? {
        let spoken = normalized(transcript)
        guard !spoken.isEmpty else { return nil }
        for (trigger, text) in snippets where normalized(trigger) == spoken {
            return text
        }
        return nil
    }

    /// Replaces each trigger phrase inside longer text with its snippet. Runs after cleanup, so the model never sees the snippet.
    static func expandSnippets(_ text: String, _ snippets: [String: String]) -> String {
        replacePhrases(in: text, snippets)
    }

    /// The last touch a style makes on its own, so it holds even when cleanup is skipped for short clean text.
    static func finish(_ text: String, style: WritingStyle) -> String {
        if style == .post { return paragraphs(text) }
        guard style == .casual else { return text }
        // A chat message drops a single closing period, never an ellipsis and never one inside a list.
        guard text.hasSuffix("."), !text.hasSuffix(".."), !text.contains("\n") else { return text }
        return String(text.dropLast())
    }

    /// A post the model wrote as one block gets a paragraph per sentence, the way posts read on LinkedIn.
    /// A sentence ends at . ? or ! followed by a space and a capital, so "4.5" and "e.g. this" stay whole.
    static func paragraphs(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        return text.replacingOccurrences(of: #"([.?!])\s+(?=[A-Z0-9"“])"#, with: "$1\n\n", options: .regularExpression)
    }

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whole phrases, any case, in ONE pass: text a replacement wrote is never matched again, so "ingest" →
    /// "IngestHQ" cannot rewrite the "Ingest Data" that "ingest data" just wrote. Where phrases overlap, the
    /// longest wins. Spaces in a phrase match any run of spaces, and the replacement is pasted literally.
    private static func replacePhrases(in text: String, _ phrases: [String: String]) -> String {
        func key(_ phrase: String) -> String {
            phrase.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var lookup: [String: String] = [:]
        for (phrase, replacement) in phrases where !key(phrase).isEmpty { lookup[key(phrase)] = replacement }
        guard !lookup.isEmpty else { return text }

        let alternatives = lookup.keys.sorted { $0.count > $1.count }.map { phrase in
            phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        }
        let pattern = #"(?<![\p{L}\p{N}])(?:"# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }

        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result),
                  let replacement = lookup[key(String(result[range]))] else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

/// Turns what the Dictionary window's lists hold into settings: trimmed, no blanks, no duplicates.
extension DictionarySettings {
    static func words(fromRows rows: [String]) -> [String] {
        var seen = Set<String>()
        var words: [String] = []
        for row in rows {
            let word = row.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { continue }
            words.append(word)
        }
        return words
    }

    /// A row missing either side is dropped; when two rows share a key, ignoring case, the first one wins.
    static func pairs(fromRows rows: [(String, String)]) -> [String: String] {
        var seen = Set<String>()
        var pairs: [String: String] = [:]
        for (rawKey, rawValue) in rows {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty, seen.insert(key.lowercased()).inserted else { continue }
            pairs[key] = value
        }
        return pairs
    }

    /// Rows for a two-column list, sorted so the window shows them in the same order each time.
    static func rows(_ pairs: [String: String]) -> [(String, String)] {
        pairs.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }.map { ($0.key, $0.value) }
    }
}

extension Personalization {
    /// The word to correct from a selection in the last dictation: "Paytas," becomes "Paytas".
    static func correctionCandidate(_ selection: String) -> String? {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Personalization {
    /// How a written message might have sounded when spoken: lowercase, no punctuation, a filler or two.
    /// Paired with the message itself, it shows cleanup what the speaker's own finished text looks like.
    static func spokenForm(_ text: String) -> String {
        let keep = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "'$%"))
        var words = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: keep.inverted).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 3 else { return words.joined(separator: " ") }
        words.insert("um", at: 1)
        words.insert("uh", at: words.count / 2)
        return words.joined(separator: " ")
    }

    /// Up to `limit` of your own messages for a style, as spoken → written example pairs. Lines with a link are
    /// left out of each message, since nobody speaks a URL.
    static func personalExamples(_ settings: AppSettings, style: WritingStyle, limit: Int = 3) -> [(spoken: String, written: String)] {
        (settings.styleExamples[style.rawValue] ?? []).prefix(limit).compactMap { message in
            let written = message.components(separatedBy: "\n")
                .filter { !$0.contains("http://") && !$0.contains("https://") }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return written.isEmpty ? nil : (spokenForm(written), written)
        }
    }
}
