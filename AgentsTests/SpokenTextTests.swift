// AgentsTests/SpokenTextTests.swift
import XCTest

@testable import Agents

/// What of a reply is read aloud. A Claude Code answer is written for a
/// screen; read verbatim, a table is "pipe dash dash pipe".
final class SpokenTextTests: XCTestCase {
    func testProseIsKeptAndMarkdownMarksGo() {
        XCTAssertEqual(
            SpokenText.from("**Yes.** Atlas is up, see [the logs](https://x/y)."),
            "Yes. Atlas is up, see the logs.")
    }

    func testCodeBlocksAreDroppedAndSaidSo() {
        XCTAssertEqual(
            SpokenText.from("Run this:\n```bash\nls -la\n```\nThat's it."),
            "Run this: That's it. The rest is in the chat.")
    }

    func testTablesAreDroppedAndSaidSo() {
        XCTAssertEqual(
            SpokenText.from("Status:\n| a | b |\n|---|---|\n| 1 | 2 |\nAll good."),
            "Status: All good. The rest is in the chat.")
    }

    /// Inline code is usually a name. Dropping it would leave "Restarted just now."
    func testInlineCodeIsReadAsPlainText() {
        XCTAssertEqual(
            SpokenText.from("Restarted `rack-hub` just now."),
            "Restarted rack-hub just now.")
    }

    /// A list item gets a full stop so the voice pauses between items instead
    /// of running "disk memory" together.
    func testListItemsAndHeadingsBecomeSentences() {
        XCTAssertEqual(
            SpokenText.from("# Checked\n- **disk**\n- memory"),
            "Checked. disk. memory.")
    }

    func testLongAnswersAreCutAtTheLastSentenceInsideTheCap() {
        let long = Array(repeating: "Word word word.", count: 60).joined(separator: " ")
        XCTAssertEqual(
            SpokenText.from(long),
            String(repeating: "Word word word. ", count: 36) + SpokenText.restIsInTheChat)
    }

    func testAShortCleanAnswerHasNoSuffix() {
        XCTAssertEqual(SpokenText.from("Yes."), "Yes.")
    }

    func testAnAnswerThatIsAllCodeSaysWhereItIs() {
        XCTAssertEqual(SpokenText.from("```\nls\n```"), SpokenText.allInTheChat)
    }

    // MARK: - Cap cut is word-based, not a character scan

    /// THE BUG: scanning for the last '.' CHARACTER lands inside "91.5" when
    /// nothing later in the cap is a real sentence end. The fix must fall
    /// back to the last real sentence before it instead.
    func testCapCutDoesNotBreakInsideADecimalNearTheCap() {
        let opening = Array(repeating: "Word word word.", count: 20).joined(separator: " ")
        let filler = Array(repeating: "word", count: 44).joined(separator: " ")
        let tail = "at 91.5 percent word word word word word word word word word word"
        XCTAssertEqual(
            SpokenText.from("\(opening) \(filler) \(tail)"),
            String(repeating: "Word word word. ", count: 20) + SpokenText.restIsInTheChat)
    }

    /// Same bug, a version number: several '.' characters in one word, none of
    /// them a sentence end.
    func testCapCutDoesNotBreakInsideAMultiDotNumberNearTheCap() {
        let opening = Array(repeating: "Word word word.", count: 20).joined(separator: " ")
        let filler = Array(repeating: "word", count: 44).joined(separator: " ")
        let tail = "reachable at 3.14.159 from word word word word word word word word word"
        XCTAssertEqual(
            SpokenText.from("\(opening) \(filler) \(tail)"),
            String(repeating: "Word word word. ", count: 20) + SpokenText.restIsInTheChat)
    }

    /// No word inside the cap ends a sentence at all: fall back to the cap
    /// itself, marked with an ellipsis.
    func testCapCutFallsBackToEllipsisWhenNoSentenceEndsInsideTheCap() {
        let words = Array(repeating: "word", count: 120).joined(separator: " ")
        let expectedHead = Array(repeating: "word", count: 110).joined(separator: " ")
        XCTAssertEqual(
            SpokenText.from(words),
            expectedHead + "…" + " " + SpokenText.restIsInTheChat)
    }

    // MARK: - URLs and images have nothing to read

    func testBareURLsAreDroppedAndSaidSo() {
        XCTAssertEqual(
            SpokenText.from("Opened the PR: https://github.com/x/y/pull/42"),
            "Opened the PR: The rest is in the chat.")
    }

    func testAngleBracketURLIsDropped() {
        XCTAssertEqual(
            SpokenText.from("See <https://example.com/status> for details."),
            "See for details. The rest is in the chat.")
    }

    /// A picture has no text under it at all, not even a link's visible words
    /// - the whole thing, "!" included, just isn't there.
    func testImagesAreDroppedEntirely() {
        XCTAssertEqual(
            SpokenText.from("Here is a chart: ![dashboard](https://x/y.png) done."),
            "Here is a chart: done. The rest is in the chat.")
    }

    // MARK: - A paragraph break is not a wrapped sentence

    /// THE BUG: two paragraphs run together with no stop between them -
    /// "Summary All three nodes are up. Next Nothing to do". A blank line
    /// ends whatever came before it. The very last paragraph, when nothing
    /// else about the reply was dropped, is left exactly as any other clean,
    /// single-paragraph reply is - the tests below cover the cases that DO
    /// need closing without a blank line (into a list, into a fence), even
    /// at the very end of the text.
    func testParagraphBreakEndsTheSentenceBeforeIt() {
        XCTAssertEqual(
            SpokenText.from("**Summary**\n\nAll three nodes are up.\n\n**Next**\n\nNothing to do"),
            "Summary. All three nodes are up. Next. Nothing to do")
    }

    /// THE BUG: a bold line running straight into a list with no blank line
    /// between them stayed open - "What changed Endpointer now waits.".
    func testCloseParagraphFiresBeforeAHeadingLikeLineIntoAList() {
        XCTAssertEqual(
            SpokenText.from("**What changed**\n- Endpointer now waits\n- Transcriber routes buffers"),
            "What changed. Endpointer now waits. Transcriber routes buffers.")
    }

    /// Same bug, plain prose (not bold) straight into a list.
    func testCloseParagraphFiresBeforeAPlainLineIntoAList() {
        XCTAssertEqual(
            SpokenText.from("I checked three things\n- disk\n- memory"),
            "I checked three things. disk. memory.")
    }

    /// Same bug, prose straight into a fence with no blank line between them.
    func testCloseParagraphFiresBeforeAFenceWithNoBlankLine() {
        XCTAssertEqual(
            SpokenText.from("Run this\n```\nls\n```"),
            "Run this. The rest is in the chat.")
    }

    // MARK: - A removed URL must not take the sentence's own punctuation with it

    /// THE BUG: `[^\s>]+` swallowed the period after the URL too, merging
    /// "...at" straight into "CI is green" with no stop between them.
    func testURLRemovalDoesNotSwallowTheSentenceEndAfterIt() {
        XCTAssertEqual(
            SpokenText.from("Opened the PR at https://github.com/x/pull/42. CI is green."),
            "Opened the PR at. CI is green. The rest is in the chat.")
    }

    /// THE BUG: the same greedy match swallowed a closing ")" right after
    /// the URL, leaving "(see" with no matching close at all.
    func testURLRemovalDoesNotSwallowAClosingParenthesis() {
        XCTAssertEqual(
            SpokenText.from("Merged (see https://github.com/x/pull/42) and deployed."),
            "Merged (see ) and deployed. The rest is in the chat.")
    }

    /// THE BUG: the old fix for the space-before-punctuation problem was a
    /// SECOND, global "\s+([.,!?;:])" pass over the WHOLE text - so it also
    /// fired on any other space-before-punctuation in the same reply that
    /// had nothing to do with the removed URL, turning "the .env file" into
    /// "the.env file" and "at .5 mm" into "at.5 mm" just because a URL
    /// happened to appear somewhere else in the answer.
    func testURLRemovalDoesNotMangleUnrelatedDotsElsewhereInTheReply() {
        XCTAssertEqual(
            SpokenText.from("Edit the .env file, then see https://x.com/docs."),
            "Edit the .env file, then see. The rest is in the chat.")
        XCTAssertEqual(
            SpokenText.from("It's .5 mm thick, see https://x.com/docs for the spec."),
            "It's .5 mm thick, see for the spec. The rest is in the chat.")
    }

    /// The fix above must not regress the exact case it replaces: still no
    /// stray space before the sentence's own full stop once the URL right
    /// before it is gone.
    func testURLRemovalStillLeavesNoStraySpaceBeforeTheFullStop() {
        XCTAssertEqual(
            SpokenText.from("Opened the PR at https://x/pull/42. CI is green."),
            "Opened the PR at. CI is green. The rest is in the chat.")
    }

    /// THE BUG: a quoted URL leaves an empty pair of quotes behind once the
    /// URL itself is gone - 'Open "" now.' reads as a stray mark with
    /// nothing between it, so the empty pair goes with the URL.
    func testQuotedURLDropsTheEmptyQuotesItLeavesBehind() {
        XCTAssertEqual(
            SpokenText.from("Open \"https://x.com/a\" now."),
            "Open now. The rest is in the chat.")
    }

    // MARK: - Fences other than backticks, and fences inside fences

    func testTildeFencesAreDroppedLikeBacktickFences() {
        XCTAssertEqual(
            SpokenText.from("Before.\n~~~\ncode here\n~~~\nAfter."),
            "Before. After. The rest is in the chat.")
    }

    /// A ```swift fence nested inside a ````markdown fence has FEWER
    /// backticks than the one that opened it, so it must not close it - no
    /// code from either fence may leak into the spoken text.
    func testNestedFenceDoesNotCloseOnAShorterMarker() {
        let markdown = "Explaining code blocks.\n````markdown\nExample:\n```swift\nlet x = 1\n```\n````\nDone."
        XCTAssertEqual(
            SpokenText.from(markdown),
            "Explaining code blocks. Done. The rest is in the chat.")
    }

    // MARK: - Emphasis stripping must not touch code or arithmetic

    /// THE BUG: stripping every '*' character turns `*.orig` into ".orig".
    func testInlineCodeProtectsAsterisksFromEmphasisStripping() {
        XCTAssertEqual(SpokenText.from("Run `*.orig` cleanup"), "Run *.orig cleanup")
    }

    /// THE BUG: stripping every '*' character turns "2*3=6" into "23=6".
    /// Only a matched PAIR of asterisks is emphasis; a lone one is arithmetic.
    func testArithmeticAsteriskIsNotEmphasis() {
        XCTAssertEqual(SpokenText.from("2*3=6"), "2*3=6")
    }

    /// THE BUG: a MATCHED pair of single asterisks either side of a digit is
    /// still arithmetic, not italic - "2*3*4 = 24" became "234 = 24".
    func testAsteriskPairAroundADigitIsNotEmphasis() {
        XCTAssertEqual(SpokenText.from("2*3*4 = 24"), "2*3*4 = 24")
    }

    /// THE BUG: same thing for a shell glob - "Delete *.tmp and *.log files."
    /// became "Delete .tmp and .log files.".
    func testGlobAsterisksAreNotEmphasis() {
        XCTAssertEqual(SpokenText.from("Delete *.tmp and *.log files."), "Delete *.tmp and *.log files.")
    }

    /// Genuine italic still strips: a word-boundary asterisk pair with no
    /// letter or digit touching either outer side.
    func testGenuineItalicStillStrips() {
        XCTAssertEqual(SpokenText.from("*Note:* the disk is full."), "Note: the disk is full.")
    }

    /// THE BUG: a stray, unpaired backtick gets greedily paired with the NEXT
    /// real backtick by the code-span regex instead of being left alone,
    /// leaving the other one dangling onto whatever follows it -
    /// "Press the key, then run ls`.".
    func testStrayBacktickDoesNotDangleOntoTheNextWord() {
        XCTAssertEqual(
            SpokenText.from("Press the ` key, then run `ls`."),
            "Press the key, then run ls.")
    }

    // MARK: - Minor fixes

    /// THE BUG: "- **Disk is fine.**" gave "Disk is fine.." - the list-item
    /// stop was decided on the raw line, which ends in "**" not ".".
    func testListItemAlreadyEndingInAPeriodIsNotDoubled() {
        XCTAssertEqual(SpokenText.from("- **Disk is fine.**"), "Disk is fine.")
    }

    /// A divider has nothing to read, and a task box is a checkbox, not words.
    func testHorizontalRulesAreDroppedAndTaskBoxesAreStripped() {
        XCTAssertEqual(
            SpokenText.from("Before.\n---\n- [ ] Ship it\n- [x] Done"),
            "Before. Ship it. Done.")
    }

    // MARK: - Performance guard: the input itself is bounded

    /// PERFORMANCE GUARD: without bounding the input up front, a reply with
    /// thousands of code spans makes extractCodeSpans/restoreCodeSpans
    /// rescan the whole text once per span - quadratic. Not timed here
    /// (flaky in CI); this just confirms the cap is applied and reported as
    /// dropped content, the way any other truncation is.
    func testInputLongerThanTheCapIsTruncatedAndMarkedDropped() {
        let text = String(repeating: "a", count: 20_100)
        let result = SpokenText.from(text)
        XCTAssertTrue(result.hasSuffix(SpokenText.restIsInTheChat))
        XCTAssertFalse(result.contains(String(repeating: "a", count: 20_100)))
    }

    /// THE BUG: restoreCodeSpans used to rescan the WHOLE text once per code
    /// span (a `replacingOccurrences` call in a loop) - quadratic. 5,000
    /// short spans ("`a`", one per word so the 20k character cap doesn't cut
    /// any of them off) must restore in well under a second; the old
    /// implementation took vastly longer at this size.
    func testManyCodeSpansRestoreWithoutQuadraticSlowdown() {
        let text = Array(repeating: "`a`", count: 5_000).joined(separator: " ")
        let start = Date()
        _ = SpokenText.from(text)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}
