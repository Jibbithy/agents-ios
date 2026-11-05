// AgentsTests/BargeInTests.swift
import XCTest

@testable import Agents

final class BargeInTests: XCTestCase {
    /// The mic hearing the answer back out of the speaker. Nothing new in it,
    /// so Atlas goes on talking.
    func testTheAnswerHeardBackIsNotSomeoneTalking() {
        XCTAssertFalse(BargeIn.isUser(heard: "all up", speaking: ["All up.", "Everything is running."]))
        XCTAssertFalse(
            BargeIn.isUser(
                heard: "everything is running all up",
                speaking: ["All up.", "Everything is running."]))
    }

    func testTwoWordsThatAreNotTheAnswerAreSomeoneTalking() {
        XCTAssertTrue(BargeIn.isUser(heard: "wait stop", speaking: ["All up.", "Everything is running."]))
    }

    /// ONE new word is not enough: a recogniser hearing the answer through the
    /// speaker mishears a word here and there, and every one of those would
    /// cut Atlas off mid-sentence.
    func testOneWordThatIsNotTheAnswerIsNotEnough() {
        XCTAssertFalse(BargeIn.isUser(heard: "all app", speaking: ["All up."]))
    }

    /// The real case: the mic hears the tail of the answer and the start of
    /// the question in one transcript.
    func testTheAnswerAndThenAQuestionIsSomeoneTalking() {
        XCTAssertTrue(
            BargeIn.isUser(
                heard: "everything is running what about hermes",
                speaking: ["All up.", "Everything is running."]))
    }

    func testCaseAndPunctuationAreFolded() {
        XCTAssertFalse(BargeIn.isUser(heard: "ALL UP!", speaking: ["all up"]))
        XCTAssertFalse(
            BargeIn.isUser(
                heard: "it's up, at 3.14.159.",
                speaking: ["It's up at 3.14.159"]))
        XCTAssertFalse(BargeIn.isUser(heard: "state of the art", speaking: ["State-of-the-art."]))
    }

    /// Nothing is being read, so there is no echo it could be: two words are
    /// two words. (The session only listens over a reading, so this is the
    /// gap between one chunk and the next.)
    func testWithNothingBeingSaidAnyTwoWordsCount() {
        XCTAssertTrue(BargeIn.isUser(heard: "hey atlas", speaking: []))
        XCTAssertFalse(BargeIn.isUser(heard: "atlas", speaking: []))
    }

    /// TWO DIFFERENT WORDS, not one word twice. A recogniser doubling a word
    /// it half-heard through the speaker ("no no") is exactly the false
    /// positive the two-word rule is there to stop.
    func testTheSameNewWordTwiceIsOneWord() {
        XCTAssertFalse(BargeIn.isUser(heard: "hermes hermes", speaking: ["All up."]))
        XCTAssertFalse(BargeIn.isUser(heard: "all up up", speaking: ["All up."]))
        XCTAssertTrue(BargeIn.isUser(heard: "hermes hermes too", speaking: ["All up."]))
    }

    func testNothingHeardIsNotSomeoneTalking() {
        XCTAssertFalse(BargeIn.isUser(heard: "", speaking: []))
        XCTAssertFalse(BargeIn.isUser(heard: "   ", speaking: ["All up."]))
    }
}
