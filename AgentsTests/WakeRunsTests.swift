// AgentsTests/WakeRunsTests.swift
import XCTest

@testable import Agents

/// Stands in for runs of the wake word's listener: each listens until its
/// task is cancelled, then lets go - taking as long as the test says, as the
/// real stop does, hopping to the listener's actor. Every run logs to one
/// list, so a test can read the order they happened in.
@MainActor final class FakeWakeListener {
    private(set) var events: [String] = []
    /// The next let-go waits for `letGoNow`.
    var holdsLetGo = false
    private var letting: CheckedContinuation<Void, Never>?

    var lettingGo: Bool { letting != nil }

    func run(_ name: String) async {
        events.append("\(name) listening")
        // Until the run is stopped - the real one waits on a hit that never comes.
        try? await Task.sleep(for: .seconds(3600))
        if holdsLetGo { await withCheckedContinuation { letting = $0 } }
        events.append("\(name) let go")
    }

    func letGoNow() {
        letting?.resume()
        letting = nil
    }
}

@MainActor
final class WakeRunsTests: XCTestCase {
    private func until(
        _ condition: @autoclosure () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting", file: file, line: line)
    }

    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    /// What the voice session's mic waits on: not the stop being ASKED for,
    /// the stop having LANDED.
    func testReleaseReturnsOnlyOnceTheRunHasLetGo() async {
        let runs = WakeRuns()
        let wake = FakeWakeListener()
        wake.holdsLetGo = true
        runs.start { await wake.run("a") }
        await until(wake.events == ["a listening"])
        let released = Flag()
        Task {
            await runs.release()
            released.on = true
        }
        await until(wake.lettingGo)
        await settle()
        XCTAssertFalse(released.on)
        wake.letGoNow()
        await until(released.on)
        XCTAssertEqual(wake.events, ["a listening", "a let go"])
        XCTAssertFalse(runs.running)
    }

    /// A restart - a route change, the app back on screen - must not have a
    /// new listener take the session while the old one is still letting go:
    /// the old one's deactivation would land on the new one.
    func testTheNextRunStartsOnlyOnceTheLastHasLetGo() async {
        let runs = WakeRuns()
        let wake = FakeWakeListener()
        wake.holdsLetGo = true
        runs.start { await wake.run("a") }
        await until(wake.events == ["a listening"])
        runs.stop()
        runs.start { await wake.run("b") }
        await until(wake.lettingGo)
        await settle()
        XCTAssertEqual(wake.events, ["a listening"])
        wake.holdsLetGo = false
        wake.letGoNow()
        await until(wake.events == ["a listening", "a let go", "b listening"])
        await runs.release()
        XCTAssertEqual(wake.events, ["a listening", "a let go", "b listening", "b let go"])
    }

    func testStartingTwiceIsOneRun() async {
        let runs = WakeRuns()
        let wake = FakeWakeListener()
        runs.start { await wake.run("a") }
        runs.start { await wake.run("b") }
        await until(wake.events == ["a listening"])
        await settle()
        await runs.release()
        XCTAssertEqual(wake.events, ["a listening", "a let go"])
    }

    /// Stopped while waiting on the run before it: it never starts at all.
    func testARunStoppedBeforeItsTurnNeverListens() async {
        let runs = WakeRuns()
        let wake = FakeWakeListener()
        wake.holdsLetGo = true
        runs.start { await wake.run("a") }
        await until(wake.events == ["a listening"])
        runs.stop()
        runs.start { await wake.run("b") }
        runs.stop()
        await until(wake.lettingGo)
        wake.letGoNow()
        await runs.release()
        await settle()
        XCTAssertEqual(wake.events, ["a listening", "a let go"])
    }

    /// A listener that would not start ends its run by itself. The next
    /// `start` - the next scene or session change - must try again, not find
    /// a run still "wanted" and do nothing.
    func testARunThatEndedByItselfCanStartAgain() async {
        let runs = WakeRuns()
        let wake = FakeWakeListener()
        let tried = Flag()
        runs.start { tried.on = true }
        await until(tried.on)
        await until(!runs.running)
        runs.start { await wake.run("b") }
        await until(wake.events == ["b listening"])
        await runs.release()
        XCTAssertEqual(wake.events, ["b listening", "b let go"])
    }
}

final class WakeBackoffTests: XCTestCase {
    /// A mic that keeps giving up is retried less and less often, never
    /// more than a minute apart - not in a loop.
    func testDoublesUpToAMinute() {
        var backoff = WakeBackoff()
        let waits = (0..<7).map { _ in backoff.next() }
        XCTAssertEqual(
            waits,
            [
                .seconds(5), .seconds(10), .seconds(20), .seconds(40),
                .seconds(60), .seconds(60), .seconds(60),
            ])
    }

    /// A run that scored means the mic and the model worked: the next give-up
    /// is a fresh one.
    func testAScoreStartsItOver() {
        var backoff = WakeBackoff()
        _ = backoff.next()
        _ = backoff.next()
        _ = backoff.next()
        backoff.reset()
        XCTAssertEqual(backoff.next(), .seconds(5))
        XCTAssertEqual(backoff.next(), .seconds(10))
    }
}
