// AgentsTests/TranscriberTests.swift
import XCTest

@testable import Agents

/// The one rule the recogniser's results go through before they become the
/// transcript. Pure, so the phone's failures - a final result with no text,
/// after partials that had the word; a recogniser that starts over after a
/// pause - are pinned down on strings.
final class TranscriberTests: XCTestCase {
    /// The transcript after a result, with nothing kept from a restart.
    private func revise(_ heard: String, _ text: String?) -> String? {
        Transcriber.revision(kept: "", latest: heard, to: text).map { Transcriber.joined($0.kept, $0.latest) }
    }

    /// Feeds results in order, as the recogniser would, and returns the
    /// transcript the listen ends with.
    private func transcript(_ results: [String?]) -> String {
        var kept = ""
        var latest = ""
        for text in results {
            if let next = Transcriber.revision(kept: kept, latest: latest, to: text) { (kept, latest) = next }
        }
        return Transcriber.joined(kept, latest)
    }

    func testNewWordsReplaceTheTranscript() {
        XCTAssertEqual(revise("", "Dis"), "Dis")
        XCTAssertEqual(revise("Dis", "Dismissed."), "Dismissed.")
        XCTAssertEqual(
            revise("Dismissed.", "Dismiss"), "Dismiss",
            "a shorter revision is still the recogniser's latest word on it")
    }

    func testAnEmptyResultNeverEmptiesTheTranscript() {
        // The on-device recogniser's FINAL result for "Dismissed" came back
        // empty five times in a row on the phone (2026-09-23); the partial
        // is what was said.
        XCTAssertNil(revise("Dismissed.", ""))
        XCTAssertNil(revise("Dismissed.", nil))
        XCTAssertNil(revise("", ""))
        XCTAssertNil(revise("", nil))
    }

    func testTheSameTextIsNotAChange() {
        XCTAssertNil(revise("Dismissed.", "Dismissed."))
    }

    func testARecogniserThatStartsOverKeepsWhatWasSaid() {
        // iOS 18 after a pause: everything before it dropped, only the new
        // words reported (2026-10-21, "it forgets everything I said").
        XCTAssertEqual(
            transcript([
                "Text", "Text Heather", "Text Heather that the truck", "Text Heather that the truck is late.",
                "Tell", "Tell her", "Tell her around five.",
            ]),
            "Text Heather that the truck is late. Tell her around five.")
    }

    func testItCanStartOverMoreThanOnce() {
        XCTAssertEqual(
            transcript(["What's the weather", "In", "In Salt Lake City", "And", "And tomorrow"]),
            "What's the weather In Salt Lake City And tomorrow")
    }

    func testAWholeTranscriptAfterARestartReplacesIt() {
        // A final result that has every word again must not repeat them.
        XCTAssertEqual(
            transcript(["Text Heather the truck", "Is late", "Text Heather the truck is late."]),
            "Text Heather the truck is late.")
    }

    func testARevisionThatShrinksOnTheSameFirstWordIsStillARevision() {
        XCTAssertEqual(transcript(["Send it to the", "Send it."]), "Send it.")
    }
}
