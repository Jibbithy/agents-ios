import SwiftUI
// AgentsTests/TurnResumeTests.swift
import XCTest

@testable import Agents

/// A hub the test plays by hand: each send or attach opens a stream whose
/// events the test yields and whose death the test decides.
@MainActor
final class FakeHub {
    var sends: [(message: String, attach: Attach)] = []
    var attaches: [(conversation: String, from: Int)] = []
    var cancelled: [String] = []
    /// Streams the app hung up on - what the hub sees as a socket closing.
    var hungUp = 0
    private var current: AsyncThrowingStream<SSEEvent, Error>.Continuation?

    var streams: Streams {
        Streams(
            send: { [unowned self] _, message, attach in
                self.sends.append((message, attach))
                return self.open()
            },
            attach: { [unowned self] conversation, from in
                self.attaches.append((conversation, from))
                return self.open()
            },
            cancel: { [unowned self] id in self.cancelled.append(id) })
    }

    private func open() -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { c in
            c.onTermination = { @Sendable reason in
                guard case .cancelled = reason else { return }
                Task { @MainActor in self.hungUp += 1 }
            }
            current = c
        }
    }

    func conversation(_ id: String) { yield("conversation", "{\"conversation\":\"\(id)\"}", seq: nil) }
    func text(_ t: String, seq: Int) { yield("text", "{\"text\":\"\(t)\"}", seq: seq) }
    func done(seq: Int) { yield("done", "{}", seq: seq) }
    /// The socket died - what iOS does to a backgrounded app's stream.
    func drop() { current?.finish(throwing: ClaudeError.other("The network connection was lost.")) }
    func fail(_ e: ClaudeError) { current?.finish(throwing: e) }

    private func yield(_ event: String, _ json: String, seq: Int?) {
        current?.yield(SSEEvent(event: event, data: Data(json.utf8), seq: seq))
    }
}

/// What `LiveTurns` asked iOS for, counted by reference from its closures.
@MainActor
private final class BackgroundTime {
    var begun = 0
    var ended: [UIBackgroundTaskIdentifier] = []
    /// iOS's side of the bargain: the expiry handler it was handed.
    var expire: (@MainActor @Sendable () -> Void)?
    var pings: [(id: String, title: String, body: String)] = []
    var voice = false

    func turns() -> LiveTurns {
        LiveTurns(
            begin: { expired in
                self.begun += 1
                self.expire = expired
                return UIBackgroundTaskIdentifier(rawValue: 7)
            },
            end: { self.ended.append($0) },
            notify: { self.pings.append(($0, $1, $2)) },
            voiceLive: { self.voice })
    }
}

/// Leaving the app and coming back, driven through `ChatModel.run` with a
/// hub the test plays. The turn itself never stops - the hub buffers it - so
/// everything here is about how fast, and how quietly, the chat gets back on.
@MainActor
final class TurnResumeTests: XCTestCase {
    private func until(
        _ condition: @autoclosure () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting", file: file, line: line)
    }

    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    /// A turn with its first word on screen, mid-answer.
    private func midAnswer(_ hub: FakeHub) async -> ChatModel {
        let model = ChatModel(agent: .claude, title: "Atlas", streams: hub.streams)
        model.draft = "is atlas up"
        model.send()
        await until(hub.sends.count == 1)
        hub.conversation("c1")
        hub.text("Yes", seq: 1)
        await until(model.bubbles.count == 2 && model.bubbles[1].text == "Yes")
        return model
    }

    /// The whole point: back on screen means back on the turn NOW, from the
    /// last event rendered, and the composer never says "Reconnecting…".
    func testComingBackReattachesFromTheLastEventWithoutReconnecting() async {
        let hub = FakeHub()
        let model = await midAnswer(hub)
        model.resumeIfLive()
        await until(hub.attaches.count == 1)
        XCTAssertEqual(hub.attaches[0].conversation, "c1")
        XCTAssertEqual(hub.attaches[0].from, 2)
        XCTAssertFalse(model.reconnecting)
        XCTAssertTrue(model.busy)
        hub.text(", all up", seq: 2)
        hub.done(seq: 3)
        await until(!model.busy)
        XCTAssertEqual(model.bubbles[1].text, "Yes, all up")
        XCTAssertFalse(model.bubbles[1].incomplete)
        XCTAssertFalse(model.bubbles[1].stopped)
        XCTAssertEqual(model.threadId, "c1")
    }

    /// The socket died while the app was away, so the loop is asleep in a
    /// backoff when the app returns. That sleep is cut, not waited out.
    func testComingBackCutsABackoffShort() async {
        let hub = FakeHub()
        let model = await midAnswer(hub)
        hub.drop()
        await until(model.reconnecting)
        XCTAssertEqual(hub.attaches.count, 0)  // asleep for two seconds, not attaching yet
        let began = Date()
        model.resumeIfLive()
        await until(hub.attaches.count == 1)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
        XCTAssertFalse(model.reconnecting)
        XCTAssertEqual(hub.attaches[0].from, 2)
        hub.text(", all up", seq: 2)
        hub.done(seq: 3)
        await until(!model.busy)
        XCTAssertEqual(model.bubbles[1].text, "Yes, all up")
        XCTAssertFalse(model.bubbles[1].incomplete)
    }

    /// Nothing to get back onto: an idle chat, or a send the hub has not yet
    /// named - there is no id to attach by, and the send's own socket is
    /// still the way in, so it is left alone.
    func testNothingHappensWithNoTurnToResume() async {
        let hub = FakeHub()
        let model = ChatModel(agent: .claude, title: "Atlas", streams: hub.streams)
        model.resumeIfLive()
        await settle()
        XCTAssertTrue(hub.attaches.isEmpty)
        model.draft = "hi"
        model.send()
        await until(hub.sends.count == 1)
        model.resumeIfLive()
        await settle()
        XCTAssertTrue(hub.attaches.isEmpty)
        hub.conversation("c1")
        hub.text("Hello", seq: 1)
        hub.done(seq: 2)
        await until(!model.busy)
        XCTAssertEqual(model.bubbles.last?.text, "Hello")
    }

    /// A Stop reaches the reader the same way it always did.
    func testAStopDuringAReattachStillEndsAsAStop() async {
        let hub = FakeHub()
        let model = await midAnswer(hub)
        model.resumeIfLive()
        await until(hub.attaches.count == 1)
        model.stop()
        await until(!model.busy)
        XCTAssertTrue(model.bubbles[1].stopped)
        XCTAssertFalse(model.bubbles[1].incomplete)
        XCTAssertEqual(hub.cancelled, ["c1"])
    }

    /// Away past the hub's retention: the turn's buffer is gone but the
    /// thread is not, and the next message must continue it.
    func testAnAttachThatAgedOutKeepsTheThread() async {
        let hub = FakeHub()
        let model = await midAnswer(hub)
        model.resumeIfLive()
        await until(hub.attaches.count == 1)
        hub.fail(.gone)
        await until(!model.busy)
        XCTAssertEqual(model.threadId, "c1")
        XCTAssertTrue(model.bubbles[1].incomplete)
        XCTAssertEqual(model.bubbles.last?.kind, .error)
        model.draft = "and hermes?"
        model.send()
        await until(hub.sends.count == 2)
        guard case .conversation(let id) = hub.sends[1].attach else { return XCTFail("started a new thread") }
        XCTAssertEqual(id, "c1")
    }

    /// A 404 on the SEND still means what it always meant: the thread is gone.
    func testAGoneOnTheSendStillForgetsTheThread() async {
        let hub = FakeHub()
        let model = await midAnswer(hub)
        hub.fail(.gone)
        await until(!model.busy)
        XCTAssertNil(model.threadId)
        XCTAssertTrue(model.bubbles[1].incomplete)
    }

    // MARK: - LiveTurns

    func testBackgroundTimeIsHeldOnlyWhileATurnRuns() async {
        let time = BackgroundTime()
        let turns = time.turns()
        let hub = FakeHub()
        let model = ChatModel(agent: .claude, title: "Atlas", streams: hub.streams)
        turns.scene(.background)
        XCTAssertEqual(time.begun, 0)  // nothing running: no time asked for
        turns.scene(.active)
        turns.began(model)
        turns.scene(.background)
        XCTAssertEqual(time.begun, 1)
        turns.ended(model)
        XCTAssertEqual(time.ended, [UIBackgroundTaskIdentifier(rawValue: 7)])  // given back the moment the turn ends
        turns.began(model)  // a turn STARTED in the background asks too
        XCTAssertEqual(time.begun, 2)
        turns.scene(.active)
        XCTAssertEqual(time.ended.count, 2)
        turns.ended(model)
    }

    /// The notification shade is `.inactive` then `.active` with the socket
    /// fine the whole time; only a real trip through `.background` resumes.
    func testOnlyAReturnFromTheBackgroundResumesTurns() async {
        let turns = BackgroundTime().turns()
        let hub = FakeHub()
        let model = await midAnswer(hub)
        turns.began(model)
        turns.scene(.inactive)
        turns.scene(.active)
        await settle()
        XCTAssertTrue(hub.attaches.isEmpty)
        turns.scene(.background)
        turns.scene(.active)
        await until(hub.attaches.count == 1)
        XCTAssertEqual(hub.attaches[0].from, 2)
        hub.done(seq: 2)
        await until(!model.busy)
        turns.ended(model)
    }

    /// The thirty seconds ran out: the socket is closed ON PURPOSE - so the
    /// hub sees nobody watching and pushes on finish - and the turn parks,
    /// unmarked, until the return re-attaches it.
    func testBackgroundTimeRunningOutHangsUpAndTheReturnResumes() async {
        let time = BackgroundTime()
        let turns = time.turns()
        let hub = FakeHub()
        let model = await midAnswer(hub)
        turns.began(model)
        turns.scene(.background)
        XCTAssertNotNil(time.expire)
        time.expire?()
        await until(hub.hungUp == 1)
        await settle()
        XCTAssertEqual(time.ended.count, 1)  // time given back at expiry
        XCTAssertTrue(model.busy)  // still a turn, just parked
        XCTAssertFalse(model.reconnecting)
        XCTAssertFalse(model.bubbles[1].incomplete)
        XCTAssertTrue(hub.attaches.isEmpty)  // no re-attach while away
        turns.scene(.active)
        await until(hub.attaches.count == 1)
        XCTAssertEqual(hub.attaches[0].from, 2)
        hub.text(", all up", seq: 2)
        hub.done(seq: 3)
        await until(!model.busy)
        XCTAssertEqual(model.bubbles[1].text, "Yes, all up")
        XCTAssertFalse(model.bubbles[1].incomplete)
        turns.ended(model)
    }

    /// Parked with the socket already dead (the backoff was running when time
    /// ran out): still no re-attach until the return.
    func testExpiryDuringABackoffParksToo() async {
        let time = BackgroundTime()
        let turns = time.turns()
        let hub = FakeHub()
        let model = await midAnswer(hub)
        turns.began(model)
        turns.scene(.background)
        hub.drop()
        await until(model.reconnecting)
        time.expire?()
        await settle()
        XCTAssertTrue(hub.attaches.isEmpty)
        XCTAssertFalse(model.reconnecting)
        turns.scene(.active)
        await until(hub.attaches.count == 1)
        hub.done(seq: 2)
        await until(!model.busy)
        turns.ended(model)
    }

    /// A voice session keeps the app alive past the thirty seconds, and a
    /// parked voice turn would leave it waiting forever - so no hang-up then.
    func testAVoiceSessionKeepsTheSocket() async {
        let time = BackgroundTime()
        time.voice = true
        let turns = time.turns()
        let hub = FakeHub()
        let model = await midAnswer(hub)
        turns.began(model)
        turns.scene(.background)
        time.expire?()
        await settle()
        XCTAssertEqual(hub.hungUp, 0)
        XCTAssertEqual(time.ended.count, 1)
        hub.done(seq: 2)
        await until(!model.busy)
        turns.ended(model)
    }

    /// A Stop while parked still ends as a stop.
    func testAStopWhileParkedEndsAsAStop() async {
        let time = BackgroundTime()
        let turns = time.turns()
        let hub = FakeHub()
        let model = await midAnswer(hub)
        turns.began(model)
        turns.scene(.background)
        time.expire?()
        await until(hub.hungUp == 1)
        model.stop()
        await until(!model.busy)
        XCTAssertTrue(model.bubbles[1].stopped)
        XCTAssertEqual(hub.cancelled, ["c1"])
        turns.ended(model)
    }

    /// The ping for an answer that landed while away but still connected:
    /// the hub will not push for a turn it saw someone watching.
    func testAFinishWhileAwayPingsAndOnScreenDoesNot() async {
        let time = BackgroundTime()
        let turns = time.turns()
        let hub = FakeHub()
        let model = await midAnswer(hub)
        turns.finished(model)
        XCTAssertTrue(time.pings.isEmpty)  // on screen: nothing to say
        turns.scene(.background)
        hub.text(",  all   up", seq: 2)
        await until(model.bubbles[1].text.hasSuffix("up"))
        turns.finished(model)
        XCTAssertEqual(time.pings.count, 1)
        XCTAssertEqual(time.pings[0].id, "turn:c1")
        XCTAssertEqual(time.pings[0].title, "\(Agent.claude.deckName) finished")
        XCTAssertEqual(time.pings[0].body, "Yes, all up")
        hub.done(seq: 3)
        await until(!model.busy)
    }
}
