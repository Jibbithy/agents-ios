// Agents/Voice/BargeIn.swift
import Foundation

/// Whether what the mic heard while Atlas was talking is SOMEONE TALKING, or
/// just Atlas coming back through the speaker.
///
/// THE ECHO GUARD. Voice processing takes most of the answer back out of the
/// mic (see `AudioSessionVoice`), but not all of it: on a speaker, in a car,
/// the recogniser still catches words of the answer, and some it half-hears
/// as other words. Cutting the answer off on any of those would make Atlas
/// impossible to listen to.
///
/// So a word counts only when it is not one of the words being read right now
/// - the chunk playing and the one before it, which is what `Speaking
/// .speakingNow` returns - and it takes TWO DIFFERENT such words to count as
/// someone talking. Case and punctuation are folded, and so is the difference
/// between "state-of-the-art" and "state of the art", because the voice and
/// the recogniser do not write the same text the same way.
///
/// Pure on purpose: the one rule that decides whether Atlas can be talked
/// over is a function of two strings, tested without a mic.
enum BargeIn {
    /// How many words that are not the answer make it someone talking.
    static let newWords = 2

    /// True when `heard` has at least `newWords` different words that are not
    /// in `speaking`.
    static func isUser(heard: String, speaking: [String]) -> Bool {
        let echo = Set(speaking.flatMap(words))
        var new = Set<String>()
        for word in words(heard) where !echo.contains(word) {
            new.insert(word)
            if new.count >= newWords { return true }
        }
        return false
    }

    /// The words of `text`, folded: lower case, and split on everything that
    /// is not a letter or a number - so punctuation, hyphens and the dots in
    /// "3.14.159" are all just breaks - with apostrophes swallowed so that
    /// "it's" is one word, "its", on both sides.
    static func words(_ text: String) -> [String] {
        // Apostrophes go FIRST, and are removed rather than split on: as a
        // break, "don't" would be two words on one side and one ("dont") on
        // the other, wherever the recogniser and the voice disagree about
        // typing one.
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
