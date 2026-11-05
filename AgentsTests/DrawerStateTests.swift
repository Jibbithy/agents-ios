// AgentsTests/DrawerStateTests.swift
import XCTest

@testable import Agents

final class DrawerStateTests: XCTestCase {
    let width: CGFloat = 300

    func testStartsClosedAndFullyOffScreen() {
        let d = DrawerState()
        XCTAssertFalse(d.isOpen)
        XCTAssertEqual(d.offset(width: width), -width)
        XCTAssertEqual(d.scrimOpacity(width: width), 0, accuracy: 0.0001)
    }

    func testOpenBringsThePanelFlush() {
        var d = DrawerState()
        d.open()
        XCTAssertTrue(d.isOpen)
        XCTAssertEqual(d.offset(width: width), 0)
    }

    func testToggleGoesBothWays() {
        var d = DrawerState()
        d.toggle()
        XCTAssertTrue(d.isOpen)
        d.toggle()
        XCTAssertFalse(d.isOpen)
        XCTAssertEqual(d.offset(width: width), -width)
    }

    /// THE ONE THAT MATTERS. A closed drawer still occupies the ZStack. If it
    /// takes hit testing it silently eats every tap meant for the chat under
    /// it - the composer stops responding and nothing looks wrong.
    func testAClosedDrawerIsNotInteractive() {
        var d = DrawerState()
        XCTAssertFalse(d.isInteractive)
        d.open()
        XCTAssertTrue(d.isInteractive)
        d.close()
        XCTAssertFalse(d.isInteractive)
    }

    func testADragInProgressIsInteractiveEvenWhileClosed() {
        var d = DrawerState()
        d.track(40)
        XCTAssertTrue(d.isInteractive, "a drag opening the drawer must receive the finger")
    }

    func testDragIsClampedSoThePanelCannotOvershoot() {
        var d = DrawerState()
        d.open()
        d.track(500)  // flung right, past flush
        XCTAssertEqual(d.offset(width: width), 0, "cannot travel past open")

        d.close()
        d.track(-500)  // flung left, past hidden
        XCTAssertEqual(d.offset(width: width), -width, "cannot travel past closed")
    }

    func testScrimDarkensAsThePanelComesIn() {
        var d = DrawerState()
        d.open()
        let open = d.scrimOpacity(width: width)
        XCTAssertEqual(open, 0.35, accuracy: 0.0001, "the fully-open scrim's actual darkness, not just some positive number")

        d.close()
        d.track(width / 2)  // half-dragged open
        let half = d.scrimOpacity(width: width)
        XCTAssertGreaterThan(half, 0)
        XCTAssertLessThan(half, open)
    }

    /// A zero width happens for one frame during layout. Dividing by it would
    /// produce a NaN opacity, which SwiftUI renders as a black screen.
    func testAZeroWidthDoesNotProduceNaN() {
        var d = DrawerState()
        d.open()
        XCTAssertEqual(d.scrimOpacity(width: 0), 0, accuracy: 0.0001)
        XCTAssertFalse(d.scrimOpacity(width: 0).isNaN)
    }

    /// BOTH RESETS ARE LOAD-BEARING, and nothing held them there until this
    /// test: mutation-testing the struct found that deleting `drag = 0` from
    /// either `open()` or `close()` left the entire suite green.
    ///
    /// Task 7's gesture handler calls `drawer.track(g.translation.width)` on
    /// change and `open()`/`close()` on end. Without the reset the last
    /// translation of the gesture outlives the gesture. A drag released short
    /// of the open threshold calls `close()` with `drag == 40` still set, and
    /// at width 300 that leaves `offset == -260` - a 40pt strip of panel
    /// sitting over the chat - a permanent `scrimOpacity == 0.047` of grey,
    /// and worst of all `isInteractive == true`: a drawer that is supposed to
    /// be shut goes on eating every tap meant for the composer. That is the
    /// exact bug `isInteractive` exists to prevent, it is continuous rather
    /// than momentary, and on screen it looks like nothing at all.
    ///
    /// The `open()` half uses a NEGATIVE stale drag deliberately. A positive
    /// one is swallowed by the clamp at 0 and so proves nothing; only a
    /// leftward translation - an open drawer tugged shut and released short of
    /// the close threshold - parks the panel off flush.
    func testEndingAGestureClearsTheStaleDrag() {
        var d = DrawerState()
        d.track(40)  // released short of opening
        d.close()
        XCTAssertEqual(d.drag, 0)
        XCTAssertEqual(d.offset(width: width), -width)
        XCTAssertEqual(d.scrimOpacity(width: width), 0, accuracy: 0.0001)
        XCTAssertFalse(d.isInteractive, "a shut drawer holding a stale drag still eats every tap")

        d.track(-40)  // released short of closing
        d.open()
        XCTAssertEqual(d.drag, 0)
        XCTAssertEqual(d.offset(width: width), 0, "a stale drag must not park the panel off flush")
    }
}
