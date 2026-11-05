// Agents/Voice/SpeechChunks.swift
import Foundation

/// An answer, cut into the pieces `KokoroVoice` asks atlas for, one request
/// each.
///
/// WHY THE SIZES MATTER. Kokoro sends no audio for a request until it has
/// synthesised all of it (it streams in batches of about 200 tokens, more
/// than a chunk here), and on atlas's CPU that takes about 0.65 s per second
/// of speech, plus a fixed cost per request: "Atlas is up." took 1.0 s, a
/// 15-word sentence 3.2 s. So:
/// - THE FIRST CHUNK IS SHORT, because its synthesis is the silence before
///   Atlas says anything: up to the first comma or sentence end, and never
///   more than `firstWords`.
/// - EACH LATER ONE IS AT MOST `growth` TIMES THE ONE BEFORE, because it is
///   fetched while that one plays, and has to be ready by the time it ends.
///   Up to `mostWords`, which keeps any one request (and a failure partway
///   through it) small.
///
/// Word by word, never inside one: a '.' in "91.5" or "3.14.159" does not
/// end anything (SpokenText's rule), and nor does "e.g.".
enum SpeechChunks {
    static let firstWords = 8
    static let mostWords = 40
    /// No later chunk is held under this. After a one-word start ("Yes,"),
    /// 1.4 times the one before would be a request per word.
    static let fewestWords = 5
    /// A break before this word does not end the first chunk. See `first`.
    static let fewestFirstWords = 3

    /// 1.4 times `words`, in whole words.
    static func growth(after words: Int) -> Int {
        min(mostWords, max(fewestWords, words * 7 / 5))
    }

    /// `spoken` in order, as chunks that put back together with single
    /// spaces are the text. Empty when there is nothing to say.
    static func split(_ spoken: String) -> [String] {
        let words = spoken.split(whereSeparator: \.isWhitespace)
        var chunks: [String] = []
        var start = 0
        var previous: Int?
        while start < words.count {
            let rest = words[start...]
            let count = previous.map { later(rest, size: growth(after: $0)) } ?? first(rest)
            chunks.append(rest.prefix(count).joined(separator: " "))
            start += count
            previous = count
        }
        return chunks
    }

    /// How many of `rest`'s words the first chunk takes: through the first
    /// word that ends a sentence or a clause, if one comes in time.
    ///
    /// NOT A ONE- OR TWO-WORD CHUNK, though. "Yes," is synthesised in half a
    /// second and played in a third of one, and the five words that must
    /// follow it take about 1.3 s - a hole right after the first word. A
    /// break that early is passed over for the next one.
    private static func first(_ rest: ArraySlice<Substring>) -> Int {
        let limit = min(firstWords, rest.count)
        for (offset, word) in rest.prefix(limit).enumerated()
        where offset + 1 >= fewestFirstWords && (endsASentence(word) || endsAClause(word)) {
            return offset + 1
        }
        return cut(rest, at: limit)
    }

    /// How many of `rest`'s words a later chunk of at most `size` takes.
    ///
    /// Where a sentence ends, as far in as one does; failing that, a clause.
    /// But not in the first half: a chunk much smaller than it could be is
    /// one the next has to catch up on, so a comma further in beats a full
    /// stop a word or two in.
    private static func later(_ rest: ArraySlice<Substring>, size: Int) -> Int {
        guard rest.count > size else { return rest.count }
        let window = Array(rest.prefix(size))
        let sentence = window.lastIndex(where: endsASentence).map { $0 + 1 }
        let clause = window.lastIndex(where: endsAClause).map { $0 + 1 }
        let half = (size + 1) / 2
        let count: Int
        if let sentence, sentence >= half {
            count = sentence
        } else if let clause, clause >= half {
            count = clause
        } else {
            // NOT A BREAK IN THE FIRST HALF: a chunk much smaller than it
            // could be leaves the next one to catch up, and a sentence that
            // ends after one word would make a chunk of one word.
            count = cut(rest, at: size)
        }
        // NO TAIL OF ONE OR TWO WORDS: "chat." alone would be a round trip to
        // atlas for one word. Taken now instead, a word or two over.
        if rest.count - count <= 2, rest.count <= size + 2 { return rest.count }
        return count
    }

    /// `limit` words, or one fewer if the last is a number: "at 91.5" and
    /// then "percent" is a number cut off from what it counts.
    private static func cut(_ rest: ArraySlice<Substring>, at limit: Int) -> Int {
        guard limit > 1, limit < rest.count else { return limit }
        let last = rest[rest.startIndex + limit - 1]
        let isNumber = last.first(where: { $0.isLetter || $0.isNumber })?.isNumber == true
        return isNumber ? limit - 1 : limit
    }

    /// SpokenText's rule, less the abbreviations that end in a full stop
    /// without ending anything.
    static func endsASentence(_ word: Substring) -> Bool {
        SpokenText.endsASentence(word) && !isAbbreviation(word)
    }

    /// A comma, semicolon, colon, dash or ellipsis: a pause, if not a stop.
    static func endsAClause(_ word: Substring) -> Bool {
        guard let last = peeled(word).last else { return false }
        return ",;:—–…".contains(last)
    }

    /// "e.g.", "i.e.", "U.S.", "a.m.": letters and full stops in turn. And
    /// the titles and short forms that are only ever followed by more.
    private static func isAbbreviation(_ word: Substring) -> Bool {
        let w = peeled(word).lowercased()
        if w.range(of: #"^([a-z]\.){2,}$"#, options: .regularExpression) != nil { return true }
        return ["mr.", "mrs.", "ms.", "dr.", "st.", "vs.", "jr.", "sr.", "approx.", "cf.", "fig."].contains(w)
    }

    /// `word` without the closing quotes and brackets after its punctuation.
    private static func peeled(_ word: Substring) -> Substring {
        var w = word
        while let last = w.last, "\"')]\u{201D}\u{2019}".contains(last) { w.removeLast() }
        return w
    }
}
