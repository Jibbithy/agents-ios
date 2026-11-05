// AgentsTests/VoiceThreadTests.swift
import XCTest

@testable import Agents

/// "Continue if recent", the user's call on 2026-09-21.
final class VoiceThreadTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testAThreadUsedUnderTenMinutesAgoIsContinued() {
        let stored = VoiceThread(conversation: "c1", lastUsed: t0)
        XCTAssertEqual(VoiceThread.reusable(stored, at: t0 + 599), "c1")
    }

    func testAtTenMinutesANewThreadStarts() {
        let stored = VoiceThread(conversation: "c1", lastUsed: t0)
        XCTAssertNil(VoiceThread.reusable(stored, at: t0 + 600))
    }

    func testNothingStoredStartsANewThread() {
        XCTAssertNil(VoiceThread.reusable(nil, at: t0))
    }

    /// The clock stepped backwards (NTP, a time-zone change, a manual set):
    /// a negative interval must NOT read as "just now".
    func testAClockThatSteppedBackwardsStartsANewThread() {
        let stored = VoiceThread(conversation: "c1", lastUsed: t0)
        XCTAssertNil(VoiceThread.reusable(stored, at: t0 - 60))
    }

    func testSavedThreadsRoundTripAndTheNewestWins() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "VoiceThreadTests"))
        defaults.removePersistentDomain(forName: "VoiceThreadTests")
        XCTAssertNil(VoiceThread.load(from: defaults))

        VoiceThread(conversation: "c1", lastUsed: t0).save(to: defaults)
        VoiceThread(conversation: "c2", lastUsed: t0 + 60).save(to: defaults)
        XCTAssertEqual(VoiceThread.load(from: defaults), VoiceThread(conversation: "c2", lastUsed: t0 + 60))

        VoiceThread.clear(from: defaults)
        XCTAssertNil(VoiceThread.load(from: defaults))

        defaults.removePersistentDomain(forName: "VoiceThreadTests")
    }
}

/// Which model the next voice question goes into - `AtlasVoice.modelForNow`'s
/// whole decision, pulled out so it can be tested without a `ChatModel`.
final class VoiceThreadChoiceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A typed turn still running in the voice chat: the question goes there
    /// and is refused "Still answering.", rather than starting a new thread
    /// and pulling the screen off the answer being written.
    func testABusyModelIsReusedHoweverOldItsThread() {
        let saved = VoiceThread(conversation: "c1", lastUsed: t0)
        XCTAssertEqual(
            VoiceThread.choose(
                saved: saved,
                inMemory: (threadId: "c1", lastTurnEnded: t0, busy: true),
                at: t0 + 3_600), .reuse)
    }

    /// THE REASON THIS IS NOT JUST `reusable`. Typing or the composer mic in
    /// the voice chat never saves the thread, but is use all the same: the
    /// saved record is stale and the model's own last turn is not.
    func testAModelUsedRecentlyIsReusedWhenTheSavedThreadIsStale() {
        let saved = VoiceThread(conversation: "c1", lastUsed: t0)
        XCTAssertEqual(
            VoiceThread.choose(
                saved: saved,
                inMemory: (threadId: "c1", lastTurnEnded: t0 + 900, busy: false),
                at: t0 + 1_000), .reuse)
    }

    /// Relaunched inside the ten minutes: no model in memory, so the saved
    /// thread is re-opened by id.
    func testASavedThreadWithNoModelInMemoryIsReopened() {
        let saved = VoiceThread(conversation: "c1", lastUsed: t0)
        XCTAssertEqual(VoiceThread.choose(saved: saved, inMemory: nil, at: t0 + 60), .reopen("c1"))
    }

    func testBothStaleStartsANewThread() {
        let saved = VoiceThread(conversation: "c1", lastUsed: t0)
        XCTAssertEqual(
            VoiceThread.choose(
                saved: saved,
                inMemory: (threadId: "c1", lastTurnEnded: t0, busy: false),
                at: t0 + 600), .new)
        XCTAssertEqual(VoiceThread.choose(saved: saved, inMemory: nil, at: t0 + 600), .new)
        XCTAssertEqual(VoiceThread.choose(saved: nil, inMemory: nil, at: t0), .new)
    }

    /// A clock that stepped backwards is "not recent" for the model's own
    /// last turn too, never "always recent".
    func testAClockBehindBothStartsANewThread() {
        let saved = VoiceThread(conversation: "c1", lastUsed: t0)
        XCTAssertEqual(
            VoiceThread.choose(
                saved: saved,
                inMemory: (threadId: "c1", lastTurnEnded: t0, busy: false),
                at: t0 - 60), .new)
    }

    /// The model in memory is newer news than the saved record, which only
    /// ever describes it. Its thread went (the hub said `gone` to a typed or
    /// composer-mic turn, which saves nothing), so the saved id is dead too:
    /// re-opening it would fail the next question for nothing.
    func testAModelWhoseThreadWentIsNotReplacedByTheSavedId() {
        let saved = VoiceThread(conversation: "c1", lastUsed: t0)
        XCTAssertEqual(
            VoiceThread.choose(
                saved: saved,
                inMemory: (threadId: nil, lastTurnEnded: t0 + 30, busy: false),
                at: t0 + 60), .new)
    }
}
