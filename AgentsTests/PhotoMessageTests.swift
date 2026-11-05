import XCTest

@testable import Agents

/// The text a photo turn sends is also what history replays, so compose and
/// parse must be exact inverses - a drift shows raw paths in old bubbles.
final class PhotoMessageTests: XCTestCase {
    private let a = "/data/photos/inbox/2026-09-28_170412_1.jpg"
    private let b = "/data/photos/inbox/2026-09-28_170412_2.jpg"

    func testComposeLaysOutTextPhotosThenInstruction() {
        XCTAssertEqual(
            PhotoMessage.compose(text: "log this", paths: [a, b]),
            "log this\n\n[photo] \(a)\n[photo] \(b)\n\(PhotoMessage.instruction)")
    }

    func testComposeWithNoPhotosIsJustTheText() {
        XCTAssertEqual(PhotoMessage.compose(text: "hi", paths: []), "hi")
    }

    func testParseRoundTrips() {
        for paths in [[a], [a, b], (1...10).map { "/data/photos/inbox/x_\($0).jpg" }] {
            let p = PhotoMessage.parse(PhotoMessage.compose(text: "what is it?", paths: paths))
            XCTAssertEqual(p.text, "what is it?")
            XCTAssertEqual(p.paths, paths)
        }
    }

    func testPlainTextParsesToItself() {
        let p = PhotoMessage.parse("just words\n\nmore words")
        XCTAssertEqual(p.text, "just words\n\nmore words")
        XCTAssertEqual(p.paths, [])
    }

    /// Only the TAIL block is the attachment list. A line the user typed that
    /// happens to start with "[photo] " in the middle stays their text.
    func testPhotoLookingLineInTheMiddleIsKept() {
        let typed = "see:\n[photo] not really\nthanks"
        let p = PhotoMessage.parse(PhotoMessage.compose(text: typed, paths: [a]))
        XCTAssertEqual(p.text, typed)
        XCTAssertEqual(p.paths, [a])
    }

    /// A trailing "[photo] " line the user typed is not an attachment unless
    /// compose's whole block (separator + instruction) is there.
    func testTypedTrailingPhotoLineWithoutInstructionIsKept() {
        let typed = "see the log:\n[photo] not attached"
        let p = PhotoMessage.parse(typed)
        XCTAssertEqual(p.text, typed)
        XCTAssertEqual(p.paths, [])
    }

    func testTypedTrailingPhotoLineAfterBlankLineWithoutInstructionIsKept() {
        let typed = "see the log:\n\n[photo] not attached"
        let p = PhotoMessage.parse(typed)
        XCTAssertEqual(p.text, typed)
        XCTAssertEqual(p.paths, [])
    }

    func testFileNameIsLocalTimeAndIndex() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13:20 UTC
        XCTAssertEqual(PhotoMessage.fileName(at: date, index: 3, timeZone: utc), "2026-09-21_141320_3.jpg")
        XCTAssertEqual(PhotoMessage.fileName(at: date, index: 3, suffix: "b", timeZone: utc), "2026-09-21_141320_3b.jpg")
    }

    func testDefaultText() {
        XCTAssertEqual(PhotoMessage.defaultText(count: 1), "What's in this photo?")
        XCTAssertEqual(PhotoMessage.defaultText(count: 4), "What's in these photos?")
    }
}
