// Agents/Voice/Conversation.swift
import Foundation

/// How a hands-free conversation is set up: whether a session keeps listening
/// after each answer, and the phrases that end it.
///
/// READ ONCE PER SESSION, at `VoiceSession.trigger`: a change made in the
/// middle of a conversation applies to the next one, never half of this one.
struct VoiceSettings: Equatable, Sendable {
    static let defaultEndPhrases = ["dismissed", "that's all", "goodbye Atlas", "thanks Atlas, that's it"]

    /// Listen again after every answer, until an end phrase or a long silence.
    /// ON BY DEFAULT, for every trigger - the user's brief, 2026-09-23.
    var continuous: Bool
    var endPhrases: [String]

    init(continuous: Bool = true, endPhrases: [String] = defaultEndPhrases) {
        self.continuous = continuous
        self.endPhrases = endPhrases
    }

    private static let continuousKey = "voice.continuous"
    private static let phrasesKey = "voice.endPhrases"

    static func load(from defaults: UserDefaults = .standard) -> VoiceSettings {
        let continuous = defaults.object(forKey: continuousKey) as? Bool ?? true
        let phrases = (defaults.stringArray(forKey: phrasesKey) ?? []).filter { !$0.isBlank }
        return VoiceSettings(continuous: continuous, endPhrases: phrases.isEmpty ? defaultEndPhrases : phrases)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(continuous, forKey: Self.continuousKey)
        defaults.set(endPhrases, forKey: Self.phrasesKey)
    }

    /// The settings editor's text, one phrase a line. NEVER EMPTY: with no
    /// phrase left the only ways out of a conversation would be Cancel and
    /// half a minute of silence, which from a locked phone in a car is none.
    static func phrases(from text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isBlank }
        return lines.isEmpty ? defaultEndPhrases : lines
    }
}

extension String {
    /// Nothing a word could be made of: blank, or punctuation alone.
    fileprivate var isBlank: Bool { EndPhrase.words(self).isEmpty }
}

/// Whether what was said is the user saying goodbye.
///
/// MATCHED ON THE FINAL TRANSCRIPT OF A QUESTION, never on a partial and
/// never on the mail confirmation's listen (see `VoiceSession`). Pure, so the
/// one rule that decides whether a question reaches Atlas is tested on
/// strings.
///
/// WHOLE OR TRAILING, with a short lead-in: "ok that's all" ends it; "is that
/// all the mail?" does not (the phrase is not at the end), nor does "that's
/// all?" (asked, not said), nor "read me the first three emails, that's all"
/// (a request, with more than `maxLeadIn` words before the phrase).
enum EndPhrase {
    /// Words allowed before the phrase: "okay, great," but not a request.
    static let maxLeadIn = 3

    static func matches(_ heard: String, phrases: [String]) -> Bool {
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        // A QUESTION IS NEVER A GOODBYE. The recogniser adds punctuation.
        guard !text.isEmpty, !text.hasSuffix("?") else { return false }
        let said = words(text)
        for phrase in phrases {
            let end = words(phrase)
            guard !end.isEmpty, said.count >= end.count,
                said.count - end.count <= maxLeadIn,
                Array(said.suffix(end.count)) == end
            else { continue }
            return true
        }
        return false
    }

    /// `BargeIn.words` - lower case, punctuation gone, apostrophes swallowed
    /// ("that's" is "thats") - with the few spellings the recogniser and a
    /// person typing a phrase disagree on folded to one. Applied to both
    /// sides, so a phrase typed either way matches either transcript.
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        for word in BargeIn.words(text) {
            switch (out.last, word) {
            case ("that", "is"): out[out.count - 1] = "thats"
            case ("good", "bye"): out[out.count - 1] = "goodbye"
            case ("thank", "you"): out[out.count - 1] = "thanks"
            default: out.append(word)
            }
        }
        return out
    }
}

/// How long a conversation waits in silence before it ends itself.
///
/// COUNTED ACROSS LISTENS. Each listen gives up after five quiet seconds (see
/// `Endpointer.noSpeech`); in a conversation that only re-prompts, and it is
/// this that decides when the quiet has gone on long enough. Measured from
/// the START of the first silent listen, so 25 s is 25 s of the mic open with
/// nothing said. Words start it over.
///
/// AND COUNTED IN LISTENS TOO: a recogniser that fails quietly returns at
/// once, and on the clock alone that would be a tight loop of recognition
/// tasks for the whole limit.
struct SilenceWatch {
    enum Next: Equatable {
        /// Listen again. `chime` on the first re-prompt only: a chime every
        /// five seconds would be nagging.
        case listenAgain(chime: Bool)
        case end
    }

    static let limit: TimeInterval = 25
    static let maxListens = 8

    let limit: TimeInterval
    let maxListens: Int
    private var since: TimeInterval?
    private var listens = 0

    init(limit: TimeInterval = SilenceWatch.limit, maxListens: Int = SilenceWatch.maxListens) {
        self.limit = limit
        self.maxListens = maxListens
    }

    mutating func heardNothing(listenStarted: TimeInterval, now: TimeInterval) -> Next {
        let since = self.since ?? listenStarted
        self.since = since
        listens += 1
        if now - since >= limit || listens >= maxListens { return .end }
        return .listenAgain(chime: listens == 1)
    }

    mutating func heardWords() {
        since = nil
        listens = 0
    }
}
