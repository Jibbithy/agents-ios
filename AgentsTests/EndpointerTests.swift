// AgentsTests/EndpointerTests.swift
import XCTest
@testable import Agents

final class EndpointerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testNothingSaidGivesUpAfterFiveSeconds() {
        let e = Endpointer(started: t0)
        XCTAssertNil(e.ending(at: t0 + 4.9))
        XCTAssertEqual(e.ending(at: t0 + 5), .silent)
    }

    func testAQuestionEndsAPauseAfterTheLastNewWord() {
        var e = Endpointer(started: t0)
        e.heard(at: t0 + 2)
        XCTAssertNil(e.ending(at: t0 + 3.4))
        XCTAssertEqual(e.ending(at: t0 + 3.5), .spoke)
    }

    /// Still talking, however long it takes: every new word restarts the pause.
    func testEachNewWordRestartsThePause() {
        var e = Endpointer(started: t0)
        e.heard(at: t0 + 2)
        e.heard(at: t0 + 3)
        XCTAssertNil(e.ending(at: t0 + 4.4))
        XCTAssertEqual(e.ending(at: t0 + 4.5), .spoke)
    }

    /// The listen over an answer: open for as long as Atlas talks, however
    /// long that is, because only the session ends it.
    func testAPatientListenNeverGivesUpWaitingForAFirstWord() {
        let e = Endpointer(started: t0, patient: true)
        XCTAssertNil(e.ending(at: t0 + 5))
        XCTAssertNil(e.ending(at: t0 + 600))
    }

    /// But once someone has talked over it, it ends on the usual pause.
    func testAPatientListenStillEndsAPauseAfterTheLastWord() {
        var e = Endpointer(started: t0, patient: true)
        e.heard(at: t0 + 30)
        XCTAssertNil(e.ending(at: t0 + 31.4))
        XCTAssertEqual(e.ending(at: t0 + 31.5), .spoke)
    }

    /// Once someone has spoken, the five-second give-up no longer applies.
    func testASlowSpeakerIsNotCutOffByTheNoSpeechClock() {
        var e = Endpointer(started: t0)
        e.heard(at: t0 + 4.8)
        XCTAssertNil(e.ending(at: t0 + 5.5))
    }
}
