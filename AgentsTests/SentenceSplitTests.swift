// AgentsTests/SentenceSplitTests.swift
import XCTest

@testable import Agents

/// How an answer is cut up for Kokoro. Kokoro's first audio comes only once
/// it has synthesised the WHOLE of what it was asked for, so the first chunk
/// decides how long the phone is silent, and every chunk after it has to be
/// synthesised in the time the one before it takes to play.
final class SentenceSplitTests: XCTestCase {

    private func sizes(_ chunks: [String]) -> [Int] {
        chunks.map { $0.split(separator: " ").count }
    }

    /// `n` plain words, with no punctuation to cut at.
    private func words(_ n: Int, from start: Int = 0) -> String {
        (start..<start + n).map { "w\($0)" }.joined(separator: " ")
    }

    // MARK: - the first chunk

    func testTheFirstChunkEndsAtTheFirstComma() {
        let chunks = SpeechChunks.split("Atlas is up, and all twelve drives passed their scrub last night.")
        XCTAssertEqual(chunks.first, "Atlas is up,")
    }

    /// "Yes," on its own is synthesised in half a second and played in a
    /// third of one, and whatever follows it cannot be ready in time: a hole
    /// right after the first word. A break that early is passed over.
    func testAnEarlyBreakDoesNotMakeAOneWordFirstChunk() {
        XCTAssertEqual(SpeechChunks.split("Yes, atlas is up and running.").first, "Yes, atlas is up and running.")
        XCTAssertEqual(
            SpeechChunks.split("Yes. Atlas is up and every node answered just now.").first,
            "Yes. Atlas is up and every node answered")
    }

    func testTheFirstChunkEndsAtTheFirstSentence() {
        let chunks = SpeechChunks.split("Atlas is up. Hermes is up too, and so is calypso.")
        XCTAssertEqual(chunks.first, "Atlas is up.")
    }

    /// A long first sentence with nothing to cut at is cut at eight words,
    /// not read whole: its synthesis is the silence before Atlas speaks.
    func testTheFirstChunkIsAtMostEightWords() {
        let chunks = SpeechChunks.split(words(30))
        XCTAssertEqual(chunks.first, words(8))
    }

    /// Whichever comes first: a comma past the eighth word does not count.
    func testACommaPastEightWordsDoesNotStretchTheFirstChunk() {
        let chunks = SpeechChunks.split(words(10) + ", and the rest of it.")
        XCTAssertEqual(chunks.first, words(8))
    }

    /// Cut at the cap, a number keeps the word after it, its unit: never
    /// "at 91.5" and then "percent".
    func testAHardCutNeverStrandsANumberFromItsUnit() {
        let chunks = SpeechChunks.split("The main pool on atlas is at 91.5 percent full and climbing")
        XCTAssertEqual(chunks.first, "The main pool on atlas is at")
        XCTAssertEqual(chunks.dropFirst().first?.hasPrefix("91.5 percent"), true)
    }

    // MARK: - never inside a word

    func testNoCutInsideADecimal() {
        let chunks = SpeechChunks.split("The disk is at 91.5 percent. Memory is fine.")
        XCTAssertEqual(chunks, ["The disk is at 91.5 percent.", "Memory is fine."])
    }

    func testNoCutInsideAnIPAddress() {
        let chunks = SpeechChunks.split("Atlas is 3.14.159 on the tailnet. Hermes is next door.")
        XCTAssertEqual(chunks, ["Atlas is 3.14.159 on the tailnet.", "Hermes is next door."])
    }

    /// "e.g." and "i.e." end in a full stop and are not the end of anything.
    func testNoCutAfterAnAbbreviation() {
        let chunks = SpeechChunks.split("Pick a name e.g. atlas or hermes for it today.")
        XCTAssertEqual(chunks.first, "Pick a name e.g. atlas or hermes for")
        let later = SpeechChunks.split("Yes. Use a node i.e. atlas and then restart the hub again.")
        XCTAssertFalse(later.contains { $0.hasSuffix("i.e.") }, "\(later)")
    }

    // MARK: - the chunks after it

    /// Each chunk at most 1.4 times the one before it, so it is synthesised
    /// in the time the one before it plays. From eight words: 11, 15, 21, 29.
    func testEachChunkIsAtMostOnePointFourTimesTheOneBefore() {
        let chunks = SpeechChunks.split(words(110))
        XCTAssertEqual(sizes(chunks), [8, 11, 15, 21, 29, 26])
        let counts = sizes(chunks)
        for i in 1..<counts.count {
            XCTAssertLessThanOrEqual(counts[i], max(SpeechChunks.fewestWords, counts[i - 1] * 7 / 5))
        }
    }

    func testNoChunkIsOverFortyWords() {
        let counts = sizes(SpeechChunks.split(words(200)))
        XCTAssertEqual(counts, [8, 11, 15, 21, 29, 40, 40, 36])
    }

    /// A short first chunk does not hold the ones after it to three or four
    /// words, which would be a request per breath.
    func testAShortStartStillGrows() {
        let counts = sizes(SpeechChunks.split("Atlas is up. " + words(40)))
        XCTAssertEqual(counts.first, 3)
        XCTAssertEqual(counts.dropFirst().first, SpeechChunks.fewestWords)
    }

    /// Several short sentences go in one chunk, up to the size allowed.
    func testShortSentencesAreMerged() {
        let chunks = SpeechChunks.split("Atlas is up and healthy today. Hermes is up. Calypso is up. The Pi is up.")
        XCTAssertEqual(chunks, ["Atlas is up and healthy today.", "Hermes is up. Calypso is up.", "The Pi is up."])
    }

    /// A later chunk ends where a sentence does, when one ends far enough in,
    /// rather than mid-sentence at its size.
    func testALaterChunkEndsAtASentenceRatherThanMidway() {
        let chunks = SpeechChunks.split(words(8) + " a b c d e f g h. " + words(20, from: 100))
        XCTAssertEqual(chunks[1], "a b c d e f g h.")
    }

    /// A sentence that ends only a word or two in makes a chunk too small to
    /// keep ahead of the audio, so a comma further in wins over it.
    func testAnEarlySentenceEndLosesToALaterComma() {
        let chunks = SpeechChunks.split(words(8) + " Ok. then a b c d e, f g h i j k l m n")
        XCTAssertEqual(chunks[1], "Ok. then a b c d e,")
    }

    /// A sentence ending a word or two in is not a chunk of its own either:
    /// the next one would have to catch up from nothing.
    func testASentenceEndInTheFirstHalfIsNotAChunkOfItsOwn() {
        let chunks = SpeechChunks.split(words(8) + " Ok. " + words(20, from: 100))
        XCTAssertEqual(sizes(chunks)[1], 11)
        XCTAssertTrue(chunks[1].hasPrefix("Ok. w100"), chunks[1])
    }

    /// The last one or two words are never a request of their own: "chat."
    /// alone would be a round trip to atlas for one word.
    func testNoTailOfOneOrTwoWords() {
        let chunks = SpeechChunks.split("Atlas is up. Hermes is up. Calypso is up. The rest is in the chat.")
        XCTAssertEqual(chunks.last, "The rest is in the chat.")
        XCTAssertFalse(sizes(chunks).dropFirst().contains { $0 < 3 }, "\(chunks)")
    }

    // MARK: - edges

    func testASingleShortSentenceIsOneChunk() {
        XCTAssertEqual(SpeechChunks.split("Atlas is up."), ["Atlas is up."])
    }

    func testNothingToSayIsNoChunks() {
        XCTAssertEqual(SpeechChunks.split(""), [])
        XCTAssertEqual(SpeechChunks.split("  \n "), [])
    }

    /// Put back together, the chunks are the text: no word lost, doubled or
    /// moved.
    func testTheChunksAreTheWholeTextInOrder() {
        let text =
            "Yes, atlas is up. The disk is at 91.5 percent, e.g. fine; memory is 40.2 percent. "
            + words(90) + ". The rest is in the chat."
        let chunks = SpeechChunks.split(text)
        XCTAssertEqual(chunks.joined(separator: " "), text)
        XCTAssertFalse(chunks.contains(""))
    }
}
