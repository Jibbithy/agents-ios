// AgentsTests/WakeGateTests.swift
import XCTest

@testable import Agents

final class WakeGateTests: XCTestCase {
    func testListensOnlyWhenOnActiveAndIdle() {
        XCTAssertTrue(WakeGate.listens(enabled: true, active: true, idle: true))
    }

    func testTheToggleIsOffByDefaultAndOffMeansOff() {
        XCTAssertFalse(WakeGate.listens(enabled: false, active: true, idle: true))
    }

    /// iOS takes the mic away from a backgrounded app that isn't recording.
    /// Listening there would just fail, silently.
    func testAppInTheBackgroundDoesNotListen() {
        XCTAssertFalse(WakeGate.listens(enabled: true, active: false, idle: true))
    }

    /// While a session runs, the mic is the Transcriber's, and a reply that
    /// says "Atlas" must not set the wake word off again.
    func testABusySessionDoesNotListen() {
        XCTAssertFalse(WakeGate.listens(enabled: true, active: true, idle: false))
    }
}
