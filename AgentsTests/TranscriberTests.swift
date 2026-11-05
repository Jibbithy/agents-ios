// AgentsTests/TranscriberTests.swift
import XCTest

@testable import Agents

/// The one rule the recogniser's results go through before they become the
/// transcript. Pure, so the phone's failure - a final result with no text,
/// after partials that had the word - is pinned down on strings.
final class TranscriberTests: XCTestCase {
    func testNewWordsReplaceTheTranscript() {
        XCTAssertEqual(Transcriber.revision(of: "", to: "Dis"), "Dis")
        XCTAssertEqual(Transcriber.revision(of: "Dis", to: "Dismissed."), "Dismissed.")
        XCTAssertEqual(
            Transcriber.revision(of: "Dismissed.", to: "Dismiss"), "Dismiss",
            "a shorter revision is still the recogniser's latest word on it")
    }

    func testAnEmptyResultNeverEmptiesTheTranscript() {
        // The on-device recogniser's FINAL result for "Dismissed" came back
        // empty five times in a row on the phone (2026-09-23); the partial
        // is what was said.
        XCTAssertNil(Transcriber.revision(of: "Dismissed.", to: ""))
        XCTAssertNil(Transcriber.revision(of: "Dismissed.", to: nil))
        XCTAssertNil(Transcriber.revision(of: "", to: ""))
        XCTAssertNil(Transcriber.revision(of: "", to: nil))
    }

    func testTheSameTextIsNotAChange() {
        XCTAssertNil(Transcriber.revision(of: "Dismissed.", to: "Dismissed."))
    }
}
