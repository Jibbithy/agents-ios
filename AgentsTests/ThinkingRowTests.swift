// AgentsTests/ThinkingRowTests.swift
import XCTest

@testable import Agents

/// The elapsed counter under the thinking dots.
///
/// The dots themselves are not tested and cannot usefully be: an animation is
/// an opacity curve over time with no assertion worth writing about it. This
/// string is the part with a right and a wrong answer, which is exactly why it
/// was pulled out of the view into a free enum.
final class ElapsedTests: XCTestCase {
    func testUnderAMinuteReadsInSeconds() {
        XCTAssertEqual(Elapsed.label(0), "0s")
        XCTAssertEqual(Elapsed.label(1), "1s")
        XCTAssertEqual(Elapsed.label(12.9), "12s")  // truncates, never rounds up
        XCTAssertEqual(Elapsed.label(59), "59s")
    }

    /// The boundary in both directions. A `< 60` written as `<= 60` gives
    /// "60s" for one tick before the minutes appear, which is the kind of thing
    /// nobody sees until a turn genuinely runs that long.
    func testTheMinuteBoundary() {
        XCTAssertEqual(Elapsed.label(60), "1m 00s")
        XCTAssertEqual(Elapsed.label(61), "1m 01s")
    }

    /// ZERO-PADDED, because it is not: "2m 5s" and "2m 50s" are one glance
    /// apart at a size nobody reads carefully, and the whole row is
    /// monospaced-digit precisely so the count does not jitter.
    func testMinutesPadTheSeconds() {
        XCTAssertEqual(Elapsed.label(125), "2m 05s")
        XCTAssertEqual(Elapsed.label(150), "2m 30s")
        XCTAssertEqual(Elapsed.label(3600), "60m 00s")
    }

    /// Reachable, not paranoia - see `Elapsed.label`. A clock adjustment mid
    /// turn can put `startedAt` after the render that reads it.
    func testTimeRunningBackwardsClampsToZero() {
        XCTAssertEqual(Elapsed.label(-4), "0s")
    }
}

@MainActor
final class ChatModelStopTests: XCTestCase {
    /// Stop on a chat with nothing running must do NOTHING. The button is only
    /// on screen while `busy`, so this guard is about the race rather than the
    /// UI: a stop arriving as a turn finishes would otherwise latch `stopped`
    /// with no turn to clear it, and the NEXT turn's real failures would render
    /// as "You stopped this answer."
    func testStopOnAnIdleChatDoesNothing() {
        let model = ChatModel(agent: .claude, title: "Atlas")
        model.stop()
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.bubbles.isEmpty)
        XCTAssertNil(model.startedAt)
    }

    /// The two flags the indicator is gated on, before anything has run. The
    /// row is drawn on `busy && startedAt != nil`, so a model that reported one
    /// without the other would either hide the indicator during a live turn or
    /// draw one counting up from a stale date.
    func testAFreshChatIsNotRunningATurn() {
        let model = ChatModel(agent: .hermes(node: "calypso"), title: "Hermes")
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.startedAt)
    }

    /// An empty draft never starts a turn, so it must never start the
    /// indicator either - `startedAt` is set in `send`, after that guard.
    func testSendingBlankTextStartsNoTurn() {
        let model = ChatModel(agent: .claude, title: "Atlas")
        model.draft = "   \n "
        model.send()
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.startedAt)
        XCTAssertTrue(model.bubbles.isEmpty)
    }

    /// A stopped answer and a dropped one are two different flags on the
    /// bubble and must render as two different things - see `BubbleRow`.
    func testABubbleIsNeitherStoppedNorIncompleteByDefault() {
        let b = Bubble(kind: .assistant, text: "hi")
        XCTAssertFalse(b.stopped)
        XCTAssertFalse(b.incomplete)
    }
}
