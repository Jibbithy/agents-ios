// AgentsTests/AudioSessionVoiceTests.swift
import XCTest

@testable import Agents

/// The mic's restart budget. A restart is normally a route change, seconds
/// apart. Voice processing reconfigures the engine as it starts, and if that
/// ever posts a configuration change of its own, the mic would restart
/// itself for as long as the session lasted - taking the answer with it
/// every time. After the budget, it comes back without echo cancellation,
/// which is how the mic ran before any of this.
final class RestartBudgetTests: XCTestCase {

    func testThreeRestartsAreFineAndTheFourthIsNot() {
        var budget = RestartBudget()
        XCTAssertTrue(budget.allow(at: 100))
        XCTAssertTrue(budget.allow(at: 100.5))
        XCTAssertTrue(budget.allow(at: 101))
        XCTAssertFalse(budget.allow(at: 101.2), "four in five seconds is a loop")
    }

    /// Route changes over a long session: never a loop, however many.
    func testRestartsSpreadOutAreAlwaysAllowed() {
        var budget = RestartBudget()
        for i in 0..<20 {
            XCTAssertTrue(budget.allow(at: Double(i) * 3), "a restart every 3 s")
        }
    }

    /// A burst, then quiet: the budget fills up again.
    func testTheBudgetComesBackAfterTheWindow() {
        var budget = RestartBudget()
        for at in [0.0, 0.1, 0.2] { XCTAssertTrue(budget.allow(at: at)) }
        XCTAssertFalse(budget.allow(at: 0.3))
        XCTAssertTrue(budget.allow(at: 6), "five seconds on, the burst is forgotten")
        XCTAssertEqual(RestartBudget.window, 5)
        XCTAssertEqual(RestartBudget.limit, 3)
    }
}
