// AgentsTests/VoiceSessionTests.swift
import XCTest

@testable import Agents

// MARK: - fakes

/// `holds` makes a fake wait - for `finish`/`cancel`, `stop`, or `release` -
/// so a test can act while the session is mid-phase.
@MainActor final class FakeListener: Listening {
    var heard: String?
    var error: Error?
    var holds = false
    private(set) var listens = 0
    /// How many of those were patient: the listen held over a reading.
    private(set) var patients = 0
    private(set) var cancels = 0
    /// Called as each listen starts, patient or not - a test's clock or log.
    var onListen: ((_ patient: Bool) -> Void)?
    /// What each next non-patient listen hears, in order, before falling back to `heard`.
    var queue: [String?] = []
    /// The last listen's callback, kept so a test can call it late.
    private(set) var onWords: (@MainActor @Sendable (String) -> Void)?
    private var waiting: CheckedContinuation<String?, Error>?

    init(heard: String?) { self.heard = heard }

    func listen(patient: Bool, onWords: @escaping @MainActor @Sendable (String) -> Void) async throws -> String? {
        listens += 1
        if patient { patients += 1 }
        onListen?(patient)
        if !patient, !queue.isEmpty { heard = queue.removeFirst() }
        self.onWords = onWords
        if let error { throw error }
        // A PATIENT LISTEN NEVER ENDS ITSELF, whatever `holds` says, and
        // hears nothing until a test says so: it is the one held open over
        // an answer, waiting for someone to talk over it.
        guard holds || patient else { return heard }
        if let heard, !patient { onWords(heard) }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    /// Words arriving mid-listen, as the recogniser's partials do - and what
    /// that listen returns when it ends.
    func hears(_ words: String) {
        heard = words
        onWords?(words)
    }
    func finish() {
        waiting?.resume(returning: heard)
        waiting = nil
    }
    func cancel() {
        cancels += 1
        waiting?.resume(returning: nil)
        waiting = nil
    }
}

@MainActor final class FakeSpeaker: Speaking {
    var holds = false
    private(set) var spoken: [String] = []
    private(set) var stops = 0
    /// The app's own words, which also count as spoken.
    private(set) var said: [String] = []
    /// What it was given, while it is reading it.
    private(set) var speakingNow: [String] = []
    private var waiting: CheckedContinuation<Void, Never>?

    func speak(_ text: String) async {
        spoken.append(text)
        speakingNow = [text]
        defer { speakingNow = [] }
        guard holds else { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func say(_ text: String) async {
        said.append(text)
        await speak(text)
    }
    func stop() {
        stops += 1
        waiting?.resume()
        waiting = nil
    }
    /// The reading ended by itself, as a finished answer does - no stop.
    func release() {
        waiting?.resume()
        waiting = nil
    }
}

@MainActor final class FakeAsker: Asking {
    var answer: AskResult
    var tool: String?
    var holds = false
    private(set) var asked: [String] = []
    private(set) var cancels = 0
    /// The last ask's callback, kept so a test can call it late.
    private(set) var onTool: (@MainActor @Sendable (String) -> Void)?
    private var waiting: CheckedContinuation<AskResult, Never>?

    init(answer: AskResult) { self.answer = answer }

    func ask(_ text: String, onTool: @escaping @MainActor @Sendable (String) -> Void) async -> AskResult {
        asked.append(text)
        self.onTool = onTool
        if let tool { onTool(tool) }
        guard holds else { return answer }
        return await withCheckedContinuation { waiting = $0 }
    }
    func release() {
        waiting?.resume(returning: answer)
        waiting = nil
    }
    func cancel() {
        cancels += 1
        waiting?.resume(returning: .stopped)
        waiting = nil
    }
}

@MainActor final class FakeAudio: VoiceAudio {
    var beginError: VoiceError?
    var holds = false
    var echoCancelled = false
    private(set) var begins = 0
    private(set) var ends = 0
    private var waiting: CheckedContinuation<Void, Never>?

    func begin() async throws {
        begins += 1
        if holds { await withCheckedContinuation { waiting = $0 } }
        if let beginError { throw beginError }
    }
    func release() {
        waiting?.resume()
        waiting = nil
    }
    func end() { ends += 1 }
}

/// Whatever holds the audio session before a session's mic opens - the wake
/// word's listener. Holds its letting go until the test says it is done.
@MainActor final class FakeHolder {
    private(set) var asked = 0
    private var waiting: CheckedContinuation<Void, Never>?

    func letGo() async {
        asked += 1
        await withCheckedContinuation { waiting = $0 }
    }
    func done() {
        waiting?.resume()
        waiting = nil
    }
}

/// One session on fakes, recording every phase it publishes.
@MainActor final class Rig {
    let listener: FakeListener
    let speaker = FakeSpeaker()
    let audio = FakeAudio()
    let asker: FakeAsker
    let cues = FakeCues()
    let session: VoiceSession
    private(set) var phases: [VoicePhase] = []
    /// The session's clock, moved on by hand.
    var clock: TimeInterval = 1_000

    init(heard: String? = "is atlas up", answer: AskResult = .reply("**All up.**")) {
        listener = FakeListener(heard: heard)
        asker = FakeAsker(answer: answer)
        session = VoiceSession(listener: listener, speaker: speaker, audio: audio)
        session.onPhase = { [unowned self] in self.phases.append($0) }
        session.cues = cues
        session.now = { [unowned self] in self.clock }
    }

    /// A hands-free session: listens again after every answer.
    func converse(phrases: [String] = VoiceSettings.defaultEndPhrases) {
        session.settings = { VoiceSettings(continuous: true, endPhrases: phrases) }
    }

    var finished: Bool { phases.last == .idle }
}

/// Trips when anything `read` read changes - what a SwiftUI view that read it
/// pays a re-render for. One shot.
final class Tripwire: @unchecked Sendable {
    private(set) var tripped = false

    init(_ read: () -> Void) {
        withObservationTracking(read) { [self] in tripped = true }
    }
}

/// Set by a task, read by the test that started it.
@MainActor final class Flag {
    var on = false
}

// MARK: - tests

@MainActor
final class VoiceSessionTests: XCTestCase {
    /// Lets the session's task run until `condition` holds.
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

    /// Lets anything still queued on the main actor run, so a test can say
    /// that nothing more happened.
    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    func testASpokenQuestionIsAskedAndTheAnswerReadAloud() async {
        let r = Rig()
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, ["is atlas up"])
        XCTAssertEqual(r.speaker.spoken, ["All up."])
        XCTAssertEqual(r.phases, [.listening(heard: ""), .thinking(tool: nil), .speaking("All up."), .idle])
        XCTAssertEqual(r.audio.begins, 1)
        XCTAssertEqual(r.audio.ends, 1)
    }

    func testNothingSaidEndsQuietly() async {
        let r = Rig(heard: nil)
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, [])
        XCTAssertEqual(r.speaker.spoken, [])
        XCTAssertEqual(r.audio.ends, 1)
    }

    func testToolNamesShowWhileThinking() async {
        let r = Rig()
        r.asker.tool = "Bash"
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertTrue(r.phases.contains(.thinking(tool: "Bash")))
    }

    func testPressingAgainWhileListeningSends() async {
        let r = Rig()
        r.listener.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .listening(heard: "is atlas up"))
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, ["is atlas up"])
    }

    /// Stopping a Claude Code turn midway through a tool is Cancel's job, not
    /// a stray press's.
    func testPressingWhileThinkingIsIgnored() async {
        let r = Rig()
        r.asker.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .thinking(tool: nil))
        r.session.trigger(r.asker)
        XCTAssertEqual(r.session.phase, .thinking(tool: nil))
        XCTAssertEqual(r.listener.listens, 1)
        r.asker.release()
        await until(r.finished)
        XCTAssertEqual(r.asker.asked.count, 1)
        XCTAssertEqual(r.speaker.spoken, ["All up."])
    }

    func testPressingWhileSpeakingCutsInAndListensAgain() async {
        let r = Rig()
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .speaking("All up."))
        r.speaker.holds = false
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.speaker.stops, 1)
        XCTAssertEqual(r.listener.listens, 2)
        XCTAssertEqual(r.asker.asked.count, 2)
        XCTAssertEqual(r.audio.begins, 1, "barge-in keeps the one audio session")
    }

    func testCancelWhileListeningAsksNothing() async {
        let r = Rig()
        r.listener.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .listening(heard: "is atlas up"))
        r.session.cancel()
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, [])
        XCTAssertEqual(r.speaker.spoken, [])
    }

    func testCancelWhileThinkingCancelsTheTurn() async {
        let r = Rig()
        r.asker.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .thinking(tool: nil))
        r.session.cancel()
        await until(r.finished)
        XCTAssertEqual(r.asker.cancels, 1)
        XCTAssertEqual(r.speaker.spoken, [])
    }

    func testCancelWhileSpeakingStopsWithoutListeningAgain() async {
        let r = Rig()
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .speaking("All up."))
        r.session.cancel()
        await until(r.finished)
        XCTAssertEqual(r.speaker.stops, 1)
        XCTAssertEqual(r.listener.listens, 1)
    }

    func testAFailedTurnIsReadAloud() async {
        let r = Rig(answer: .failed("Can't reach the rack. Is Tailscale connected?"))
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.speaker.spoken, ["Can't reach the rack. Is Tailscale connected?"])
        XCTAssertTrue(r.phases.contains(.failed("Can't reach the rack. Is Tailscale connected?")))
    }

    func testNoPermissionSaysHowToFixIt() async {
        let r = Rig()
        r.listener.error = VoiceError.notAllowed
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.speaker.spoken, [VoiceSession.notAllowed])
        XCTAssertEqual(r.asker.asked, [])
    }

    /// Said, and only THEN the audio session ended. A `begin` that failed has
    /// undone itself, but reading the failure switches the session back on,
    /// ducking Spotify with nothing left to turn it off.
    func testAMicThatWontStartSaysSo() async {
        let r = Rig()
        r.audio.beginError = .micBusy
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .failed(VoiceSession.micBusy))
        XCTAssertEqual(r.audio.ends, 0, "not while it is being read")
        r.speaker.stop()
        await until(r.finished)
        XCTAssertEqual(r.speaker.spoken, [VoiceSession.micBusy])
        XCTAssertEqual(r.listener.listens, 0)
        XCTAssertEqual(r.audio.ends, 1)
    }

    /// THE APP'S OWN WORDS, said in the voice that is always there. Fetching
    /// "Mic busy." from the rack would wait out a window for a failure that
    /// has already cost the user time - see `Speaking.say`.
    func testAFailureIsSaidRatherThanSpokenAsAnAnswer() async {
        let r = Rig()
        r.audio.beginError = .micBusy
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.speaker.said, [VoiceSession.micBusy])
    }

    /// An ANSWER is not the app's own words, whatever it says.
    func testAnAnswerIsSpokenNotSaid() async {
        let r = Rig()
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.speaker.spoken, ["All up."])
        XCTAssertEqual(r.speaker.said, [])
    }

    /// From a locked phone the mic prompt cannot appear, so an unanswered one
    /// is a "no" - and "Mic busy." would send you looking for a phone call.
    func testNoMicPermissionAtTheStartSaysHowToFixIt() async {
        let r = Rig()
        r.audio.beginError = .notAllowed
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.speaker.spoken, [VoiceSession.notAllowed])
        XCTAssertEqual(r.listener.listens, 0)
        XCTAssertEqual(r.audio.ends, 1)
    }

    /// Two triggers in one main-actor turn - the Action Button and the wake
    /// word together, a double tap - are one session, not two loops on one mic.
    func testTwoPressesAtOnceAreOneSession() async {
        let r = Rig()
        r.session.trigger(r.asker)
        r.session.trigger(r.asker)
        await until(r.finished)
        await settle()
        XCTAssertEqual(r.audio.begins, 1)
        XCTAssertEqual(r.listener.listens, 1)
        XCTAssertEqual(r.phases, [.listening(heard: ""), .thinking(tool: nil), .speaking("All up."), .idle])
    }

    /// Cancel pressed before the mic is open - while `begin` waits on the
    /// audio session - must not go on to listen until the no-speech timeout.
    func testCancelBeforeTheMicOpensNeverListens() async {
        let r = Rig()
        r.audio.holds = true
        r.listener.holds = true
        r.session.trigger(r.asker)
        await until(r.audio.begins == 1)
        r.session.cancel()
        r.audio.release()
        await until(r.finished)
        XCTAssertEqual(r.listener.listens, 0)
        XCTAssertEqual(r.audio.ends, 1)
    }

    /// Cancel means quiet, even when the mic then fails on its way down.
    func testCancelThenAFailureSaysNothing() async {
        let r = Rig()
        r.audio.holds = true
        r.audio.beginError = .micBusy
        r.session.trigger(r.asker)
        await until(r.audio.begins == 1)
        r.session.cancel()
        r.audio.release()
        await until(r.finished)
        XCTAssertEqual(r.speaker.spoken, [])
    }

    /// `ListenIntent` returns on this, so it must not return while the mic is
    /// still opening.
    func testMicSettledWaitsForTheMicToOpen() async {
        let r = Rig()
        r.audio.holds = true
        r.session.trigger(r.asker)
        let settled = Flag()
        Task {
            await r.session.micSettled()
            settled.on = true
        }
        await until(r.audio.begins == 1)
        await settle()
        XCTAssertFalse(settled.on)
        r.audio.release()
        await until(settled.on)
        await until(r.finished)
    }

    /// THE MIC OPENS ONLY ONCE THE WAKE WORD HAS LET GO. Its listener's stop
    /// deactivates the shared audio session some time after it was asked;
    /// `begin` running before that landed would have the session switched
    /// off under the new mic. And the intent's wait covers the letting go too.
    func testTheMicOpensOnlyOnceTheWakeWordHasLetGo() async {
        let r = Rig()
        let wake = FakeHolder()
        r.session.beforeMic = { await wake.letGo() }
        r.session.trigger(r.asker)
        XCTAssertEqual(r.session.phase, .listening(heard: ""), "published before the mic, as ever")
        let settled = Flag()
        Task {
            await r.session.micSettled()
            settled.on = true
        }
        await until(wake.asked == 1)
        await settle()
        XCTAssertEqual(r.audio.begins, 0)
        XCTAssertFalse(settled.on)
        wake.done()
        await until(r.finished)
        XCTAssertTrue(settled.on)
        XCTAssertEqual(r.audio.begins, 1)
        XCTAssertEqual(wake.asked, 1)
        XCTAssertEqual(r.asker.asked, ["is atlas up"])
    }

    /// Or failed to open: the intent returns, and the failure is still said.
    func testMicSettledReturnsWhenTheMicFails() async {
        let r = Rig()
        r.audio.holds = true
        r.audio.beginError = .micBusy
        r.session.trigger(r.asker)
        let settled = Flag()
        Task {
            await r.session.micSettled()
            settled.on = true
        }
        await until(r.audio.begins == 1)
        await settle()
        XCTAssertFalse(settled.on)
        r.audio.release()
        await until(settled.on)
        await until(r.finished)
        XCTAssertEqual(r.speaker.spoken, [VoiceSession.micBusy])
    }

    func testCancelWhileAFailureIsReadStopsIt() async {
        let r = Rig(answer: .failed("Can't reach the rack."))
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .failed("Can't reach the rack."))
        r.session.cancel()
        await until(r.finished)
        XCTAssertEqual(r.speaker.stops, 1)
        XCTAssertEqual(r.listener.listens, 1)
        XCTAssertEqual(r.session.phase, .idle)
    }

    /// A failed TURN is cut into like a reply: the mic is fine, so ask again.
    func testPressingWhileAFailedTurnIsReadListensAgain() async {
        let r = Rig(answer: .failed("Can't reach the rack."))
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .failed("Can't reach the rack."))
        r.speaker.holds = false
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.speaker.stops, 1)
        XCTAssertEqual(r.listener.listens, 2)
        XCTAssertEqual(r.asker.asked.count, 2)
        XCTAssertEqual(r.audio.begins, 1)
    }

    /// The recogniser missing, unavailable or failing is not the mic's fault,
    /// and "Mic busy." would send you looking for a phone call.
    func testSpeechRecognitionThatFailsSaysSo() async {
        let r = Rig()
        r.listener.error = VoiceError.speechUnavailable
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.speaker.spoken, [VoiceSession.speechUnavailable])
        XCTAssertEqual(r.asker.asked, [])
        XCTAssertEqual(r.audio.ends, 1)
    }

    /// Anything else the listener throws is the mic's.
    func testAListenThatThrowsAnythingElseSaysMicBusy() async {
        struct Boom: Error {}
        let r = Rig()
        r.listener.error = Boom()
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.speaker.spoken, [VoiceSession.micBusy])
        XCTAssertEqual(r.asker.asked, [])
        XCTAssertEqual(r.audio.ends, 1)
    }

    /// A PHONE CALL MID-QUESTION. The mic has stopped hearing, and the
    /// endpointer would otherwise send Atlas half a question.
    func testAnInterruptionWhileListeningAsksNothing() async {
        let r = Rig()
        r.listener.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .listening(heard: "is atlas up"))
        r.session.interrupted()
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, [])
        XCTAssertEqual(r.speaker.spoken, [])
        XCTAssertEqual(r.audio.ends, 1)
    }

    /// Mid-answer, the reading stops - so `speak` returns and the session
    /// ends, rather than waiting in `.speaking` - and nothing listens again.
    func testAnInterruptionWhileSpeakingStopsTheReading() async {
        let r = Rig()
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .speaking("All up."))
        r.session.interrupted()
        await until(r.finished)
        XCTAssertEqual(r.speaker.stops, 1)
        XCTAssertEqual(r.listener.listens, 1)
        XCTAssertEqual(r.audio.ends, 1)
    }

    /// A call is no reason to throw away what Atlas is doing: the turn runs
    /// on, and its answer is read when it lands.
    func testAnInterruptionWhileThinkingLetsTheTurnRunOn() async {
        let r = Rig()
        r.asker.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .thinking(tool: nil))
        r.session.interrupted()
        await settle()
        XCTAssertEqual(r.asker.cancels, 0)
        XCTAssertEqual(r.session.phase, .thinking(tool: nil))
        r.asker.release()
        await until(r.finished)
        XCTAssertEqual(r.speaker.spoken, ["All up."])
    }

    /// The real listener and asker report through hops to the main actor that
    /// are not ordered with their return, so a callback can land after its
    /// step is over. It must not put a finished session back in a phase with
    /// no loop behind it, where every press after would be swallowed.
    func testALateCallbackCannotRestartAFinishedSession() async {
        let r = Rig()
        r.session.trigger(r.asker)
        await until(r.finished)
        r.listener.onWords?("late words")
        r.asker.onTool?("Bash")
        XCTAssertEqual(r.session.phase, .idle)
    }

    /// Which chat a session is asking, for the pencil: it cancels only a
    /// session whose question is going into the chat it is leaving.
    func testTheAskingIsKnownWhileASessionRuns() async {
        let r = Rig()
        r.asker.holds = true
        XCTAssertNil(r.session.asking)
        r.session.trigger(r.asker)
        XCTAssertTrue(r.session.asking === r.asker)
        await until(r.session.phase == .thinking(tool: nil))
        XCTAssertTrue(r.session.asking === r.asker)
        r.asker.release()
        await until(r.finished)
        XCTAssertNil(r.session.asking)
    }

    /// The VoiceBar's Send, which covers the composer's Talk.
    func testPressWhileListeningSends() async {
        let r = Rig()
        r.listener.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .listening(heard: "is atlas up"))
        r.session.press()
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, ["is atlas up"])
    }

    /// The VoiceBar's Talk, over an answer being read.
    func testPressWhileSpeakingListensAgain() async {
        let r = Rig()
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .speaking("All up."))
        r.speaker.holds = false
        r.session.press()
        await until(r.finished)
        XCTAssertEqual(r.speaker.stops, 1)
        XCTAssertEqual(r.listener.listens, 2)
        XCTAssertEqual(r.asker.asked.count, 2)
        XCTAssertEqual(r.audio.begins, 1)
    }

    /// Only `trigger` starts: a press has no chat to ask.
    func testPressWhileIdleDoesNothing() async {
        let r = Rig()
        r.session.press()
        await settle()
        XCTAssertEqual(r.session.phase, .idle)
        XCTAssertEqual(r.phases, [])
        XCTAssertEqual(r.audio.begins, 0)
        XCTAssertEqual(r.speaker.stops, 0)
    }

    /// The composer reads `isActive` under the bar, so the words coming in,
    /// the send and a tool starting must not re-render it: the flag is written
    /// when a session starts and when it ends, and at nothing in between.
    func testIsActiveChangesOnlyAtTheStartAndEndOfASession() async {
        let r = Rig()
        r.listener.holds = true
        r.asker.holds = true
        r.asker.tool = "Bash"
        let start = Tripwire { _ = r.session.isActive }
        r.session.trigger(r.asker)
        XCTAssertTrue(start.tripped)
        XCTAssertTrue(r.session.isActive)

        let middle = Tripwire { _ = r.session.isActive }
        await until(r.session.phase == .listening(heard: "is atlas up"))
        r.listener.onWords?("is atlas up yet")
        r.session.press()
        await until(r.session.phase == .thinking(tool: "Bash"))
        XCTAssertEqual(
            r.phases,
            [
                .listening(heard: ""), .listening(heard: "is atlas up"),
                .listening(heard: "is atlas up yet"),
                .thinking(tool: nil), .thinking(tool: "Bash"),
            ])
        XCTAssertFalse(middle.tripped, "five phase changes, and the flag was not written")

        r.asker.release()
        await until(r.finished)
        XCTAssertTrue(middle.tripped)
        XCTAssertFalse(r.session.isActive)
    }

    // MARK: - talking over Atlas

    /// TALKING OVER THE ANSWER. The words that cut Atlas off are the start of
    /// the next question, not a separate one: the SAME listen runs on to its
    /// natural end and what it heard is what is asked.
    func testTalkingOverTheAnswerStopsItAndAsksWhatWasSaid() async {
        let r = Rig()
        r.audio.echoCancelled = true
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .speaking("All up."))
        await until(r.listener.patients == 1)
        r.speaker.holds = false
        r.listener.hears("what about hermes")
        await until(r.session.phase == .listening(heard: "what about hermes"))
        XCTAssertEqual(r.speaker.stops, 1)
        XCTAssertEqual(r.listener.listens, 2, "no second listen: the one that heard it carries on")
        // The rest of the question, and then the pause that ends the listen.
        r.listener.hears("what about hermes and calypso")
        XCTAssertEqual(r.session.phase, .listening(heard: "what about hermes and calypso"))
        r.listener.finish()
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, ["is atlas up", "what about hermes and calypso"])
        XCTAssertEqual(r.audio.begins, 1, "talking over it keeps the one audio session")
    }

    /// The mic hearing the answer back out of the speaker is not someone
    /// talking - see `BargeIn`. Atlas reads on.
    func testTheAnswerHeardBackDoesNotStopIt() async {
        let r = Rig()
        r.audio.echoCancelled = true
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.listener.patients == 1)
        r.listener.hears("all up")
        await settle()
        XCTAssertEqual(r.speaker.stops, 0)
        XCTAssertEqual(r.session.phase, .speaking("All up."))
        r.speaker.release()
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, ["is atlas up"])
    }

    /// An answer read out with nobody talking over it ends the listen that
    /// was held over it. Left running, it would hold the session open with
    /// the mic on - and `until` would never see it finish.
    func testTheListenOverAnAnswerEndsWithTheAnswer() async {
        let r = Rig()
        r.audio.echoCancelled = true
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.listener.patients == 1)
        r.speaker.release()
        await until(r.finished)
        XCTAssertEqual(r.listener.cancels, 1)
        XCTAssertEqual(r.speaker.stops, 0)
        XCTAssertEqual(r.asker.asked, ["is atlas up"])
        XCTAssertEqual(r.audio.ends, 1)
    }

    /// Cancel while what was said over the answer is still being heard: the
    /// question is dropped, and the session ends.
    func testCancelWhileWhatWasSaidOverTheAnswerIsBeingHeard() async {
        let r = Rig()
        r.audio.echoCancelled = true
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.listener.patients == 1)
        r.listener.hears("what about hermes")
        await until(r.session.phase == .listening(heard: "what about hermes"))
        r.session.cancel()
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, ["is atlas up"])
        XCTAssertEqual(r.speaker.stops, 1, "stopped by the talking over, and not again")
        XCTAssertEqual(r.listener.cancels, 1)
        XCTAssertEqual(r.audio.ends, 1)
        XCTAssertEqual(r.session.phase, .idle)
    }

    /// WITHOUT ECHO CANCELLATION NOTHING LISTENS OVER THE ANSWER. The mic
    /// would hear the answer itself, and Atlas would talk itself to a stop.
    func testWithoutEchoCancellationNothingListensOverTheAnswer() async {
        let r = Rig()
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .speaking("All up."))
        await settle()
        XCTAssertEqual(r.listener.patients, 0)
        XCTAssertEqual(r.listener.listens, 1)
        r.speaker.release()
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, ["is atlas up"])
    }

    /// The press is still there, and still means "listen again" - it does not
    /// hand the listen held over the answer on as a question.
    func testPressingWhileSpeakingStillCutsInWithEchoCancellation() async {
        let r = Rig()
        r.audio.echoCancelled = true
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.listener.patients == 1)
        r.speaker.holds = false
        r.session.press()
        await until(r.finished)
        XCTAssertEqual(r.speaker.stops, 1)
        XCTAssertEqual(r.asker.asked.count, 2)
        XCTAssertEqual(
            r.listener.cancels, r.listener.patients,
            "every listen over a reading is ended with it")
        XCTAssertEqual(r.audio.begins, 1)
    }

    /// A FAILED TURN IS TALKED OVER LIKE AN ANSWER. The mic is fine - it is
    /// the rack that failed - so whoever cuts in is asking again, exactly as
    /// a press over a failed turn does.
    func testTalkingOverAFailedTurnAsksAgain() async {
        let r = Rig(answer: .failed("Can't reach the rack."))
        r.audio.echoCancelled = true
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .failed("Can't reach the rack."))
        await until(r.listener.patients == 1)
        r.speaker.holds = false
        r.listener.hears("try that again")
        await until(r.session.phase == .listening(heard: "try that again"))
        XCTAssertEqual(r.speaker.stops, 1)
        r.listener.finish()
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, ["is atlas up", "try that again"])
    }

    /// "Mic busy." is NOT talked over: the mic is the thing that failed, so
    /// there is nothing to listen with, and a press there only stops it.
    func testAMicThatWontStartIsNotListenedOver() async {
        let r = Rig()
        r.audio.echoCancelled = true
        r.audio.beginError = .micBusy
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .failed(VoiceSession.micBusy))
        await settle()
        XCTAssertEqual(r.listener.listens, 0, "no mic to listen with")
        r.speaker.stop()
        await until(r.finished)
        XCTAssertEqual(r.speaker.spoken, [VoiceSession.micBusy])
    }

    func testPhaseWording() {
        XCTAssertTrue(VoicePhase.listening(heard: "").isListening)
        XCTAssertTrue(VoicePhase.listening(heard: "is atlas up").isListening)
        XCTAssertFalse(VoicePhase.thinking(tool: nil).isListening)
        XCTAssertEqual(VoicePhase.listening(heard: "").detail, "Go ahead…")
        XCTAssertEqual(VoicePhase.listening(heard: "is atlas up").detail, "is atlas up")
        XCTAssertEqual(VoicePhase.thinking(tool: nil).detail, "Working on it…")
        XCTAssertEqual(VoicePhase.thinking(tool: "Bash").detail, "Running Bash…")
        XCTAssertEqual(VoicePhase.speaking("All up.").label, "Answer")
    }
}
