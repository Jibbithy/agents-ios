import SwiftUI
import XCTest

@testable import Agents

/// `ChatText.segments` decides what renders as prose and what as a Deck code
/// block, on every body evaluation of every agent message - including while
/// the message is still streaming in.
final class ChatTextTests: XCTestCase {

    /// The common case must be untouched: no fence, no trimming, no re-joining.
    func testTextWithoutAFenceComesBackExactly() {
        let s = "\n  Two lines,\n\nwith `inline code` and trailing space  \n"
        XCTAssertEqual(ChatText.segments(s), [.prose(s)])
    }

    func testAFencedBlockSplitsIntoProseCodeProse() {
        let s = "Before:\n\n```swift\nlet x = 1\n  let y = 2\n```\n\nAfter."
        XCTAssertEqual(
            ChatText.segments(s),
            [
                .prose("Before:"),
                .code(language: "swift", body: "let x = 1\n  let y = 2"),
                .prose("After."),
            ])
    }

    func testAFenceWithNoLanguageHasAnEmptyOne() {
        XCTAssertEqual(
            ChatText.segments("```\nls -la\n```"),
            [.code(language: "", body: "ls -la")])
    }

    /// Mid-stream the closing fence has not arrived yet. The block must render
    /// as code already, not flash as prose until it closes.
    func testAnUnclosedFenceIsCodeToTheEnd() {
        XCTAssertEqual(
            ChatText.segments("Here:\n```bash\necho hi\necho th"),
            [
                .prose("Here:"),
                .code(language: "bash", body: "echo hi\necho th"),
            ])
    }

    func testTwoBlocksBackToBack() {
        XCTAssertEqual(
            ChatText.segments("```a\n1\n```\n```b\n2\n```"),
            [
                .code(language: "a", body: "1"),
                .code(language: "b", body: "2"),
            ])
    }

    /// Blank lines INSIDE a block are code, and must survive.
    func testBlankLinesInsideABlockAreKept() {
        XCTAssertEqual(
            ChatText.segments("```\na\n\nb\n```"),
            [.code(language: "", body: "a\n\nb")])
    }

    /// Inline code loses its `.code` intent and takes Plex Mono instead - left
    /// in place, SwiftUI would swap the run back to SF Mono.
    func testInlineCodeRunsLoseTheCodeIntent() {
        let a = ChatText.prose("run `caddy validate` first")
        XCTAssertEqual(String(a.characters), "run caddy validate first")
        let codeRuns = a.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertTrue(codeRuns.isEmpty)
        let fonted = a.runs.filter { $0.font != nil }
        XCTAssertEqual(fonted.count, 1)
        XCTAssertEqual(fonted.first.map { String(a[$0.range].characters) }, "caddy validate")
    }
}

/// The name printed beside each agent's colour must be the one the picker
/// shows for that machine - otherwise the bar and the messages disagree.
final class AgentMarkTests: XCTestCase {
    func testDeckNameMatchesThePickerForEveryKnownMachine() {
        for choice in AgentChoice.all {
            XCTAssertEqual(choice.agent.deckName, choice.machine)
            XCTAssertEqual(choice.agent.deckNode, choice.node)
        }
    }
}
