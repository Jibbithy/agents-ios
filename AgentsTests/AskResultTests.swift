// AgentsTests/AskResultTests.swift
import XCTest

@testable import Agents

/// How a voice question ended, read off the bubbles its turn added. A Claude
/// Code turn is text, tool, text, tool, text: the LAST assistant bubble is the
/// answer, and the earlier ones are "let me check".
final class AskResultTests: XCTestCase {
    private func bubble(
        _ kind: Bubble.Kind, _ text: String,
        stopped: Bool = false, incomplete: Bool = false
    ) -> Bubble {
        var b = Bubble(kind: kind, text: text)
        b.stopped = stopped
        b.incomplete = incomplete
        return b
    }

    func testTheLastAssistantBubbleIsTheAnswer() {
        let added = [
            bubble(.you, "is atlas up"), bubble(.assistant, "Checking."),
            bubble(.tool, "docker ps"), bubble(.assistant, "All up."),
        ]
        XCTAssertEqual(AskResult.from(added[...]), .reply("All up."))
    }

    func testAnErrorWithNoAnswerIsTheFailure() {
        let added = [bubble(.you, "is atlas up"), bubble(.error, "Can't reach the rack. Is Tailscale connected?")]
        XCTAssertEqual(AskResult.from(added[...]), .failed("Can't reach the rack. Is Tailscale connected?"))
    }

    /// A denial after a real answer is noise to a listener; the answer wins.
    func testAnAnswerOutranksATrailingError() {
        let added = [
            bubble(.you, "restart it"), bubble(.assistant, "Done."),
            bubble(.error, "Claude was denied: Bash"),
        ]
        XCTAssertEqual(AskResult.from(added[...]), .reply("Done."))
    }

    /// "I'll restart it." is filler, and read aloud ahead of an error it
    /// sounds like success. Only text AFTER the last tool can be the answer.
    func testAFailureAfterAToolIsTheError() {
        let added = [
            bubble(.you, "restart nginx"), bubble(.assistant, "I'll restart it."),
            bubble(.tool, "systemctl restart nginx"),
            bubble(.error, "Can't reach the rack. Is Tailscale connected?"),
        ]
        XCTAssertEqual(AskResult.from(added[...]), .failed("Can't reach the rack. Is Tailscale connected?"))
    }

    /// A denied tool still gets an answer: Claude writes text after it, and
    /// that text outranks the denial bubble `done` appends.
    func testTextAfterADeniedToolIsTheAnswer() {
        let added = [
            bubble(.you, "restart nginx"), bubble(.assistant, "I'll restart it."),
            bubble(.tool, "systemctl restart nginx"),
            bubble(.assistant, "I wasn't allowed to run that."),
            bubble(.error, "Claude was denied: Bash"),
        ]
        XCTAssertEqual(AskResult.from(added[...]), .reply("I wasn't allowed to run that."))
    }

    func testFillerBeforeAToolIsNeverTheAnswer() {
        let added = [
            bubble(.you, "is atlas up"), bubble(.assistant, "Checking."),
            bubble(.tool, "docker ps"),
        ]
        XCTAssertEqual(AskResult.from(added[...]), .failed("No answer came back."))
    }

    /// Half an answer read aloud sounds like all of it.
    func testADroppedAnswerIsNotSpokenAsComplete() {
        let added = [
            bubble(.you, "is atlas up"), bubble(.assistant, "Checking."),
            bubble(.tool, "docker ps"), bubble(.assistant, "All u", incomplete: true),
        ]
        XCTAssertEqual(
            AskResult.from(added[...]),
            .failed("The connection dropped. What came through is in the chat."))
    }

    func testAStoppedAnswerIsNotSpoken() {
        let added = [bubble(.you, "is atlas up"), bubble(.assistant, "Chec", stopped: true)]
        XCTAssertEqual(AskResult.from(added[...]), .stopped)
    }

    func testNothingBackIsAFailure() {
        XCTAssertEqual(AskResult.from([bubble(.you, "hello")][...]), .failed("No answer came back."))
    }
}
