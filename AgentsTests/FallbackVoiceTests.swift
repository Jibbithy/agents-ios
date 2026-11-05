// AgentsTests/FallbackVoiceTests.swift
import XCTest

@testable import Agents

/// Kokoro, and the Apple voice whenever Kokoro can't: never silence, and
/// never the same words twice from a fallback that should not have happened.
@MainActor final class FakeChunkVoice: ChunkedSpeaking {
    /// First audio as soon as it is asked: Kokoro working.
    var audio = true
    /// What `speak` comes back with, unless stopped first.
    var result: SpeechFailure?
    /// Wait for `finish` or `stop` before coming back.
    var holds = false
    var speakingNow: [String] = []
    private(set) var spoken: [[String]] = []
    private(set) var stops = 0
    private var onFirstAudio: (@MainActor () -> Void)?
    private var waiting: CheckedContinuation<SpeechFailure?, Never>?

    func speak(_ chunks: [String], onFirstAudio: @escaping @MainActor () -> Void) async -> SpeechFailure? {
        spoken.append(chunks)
        self.onFirstAudio = onFirstAudio
        if audio { onFirstAudio() }
        guard holds else { return result }
        return await withCheckedContinuation { waiting = $0 }
    }
    /// Kokoro's first audio arrives now.
    func firstAudio() { onFirstAudio?() }
    func finish() {
        waiting?.resume(returning: result)
        waiting = nil
    }
    func stop() {
        stops += 1
        waiting?.resume(returning: nil)
        waiting = nil
    }
}

@MainActor
final class FallbackVoiceTests: XCTestCase {
    private let text =
        "Yes, atlas is up. The disk is at 91.5 percent and memory is fine. "
        + "Hermes and calypso both answered, and the backups ran at three this morning without a problem."
    private var chunks: [String] { SpeechChunks.split(text) }

    private func rig(timeout: Duration = .seconds(60)) -> (FallbackVoice, FakeChunkVoice, FakeSpeaker) {
        let kokoro = FakeChunkVoice()
        let apple = FakeSpeaker()
        return (FallbackVoice(kokoro: kokoro, apple: apple, timeout: timeout), kokoro, apple)
    }

    /// Starts reading `text`; the flag goes up when `speak` returns.
    private func start(_ voice: FallbackVoice) -> Flag {
        let done = Flag()
        let text = text
        Task {
            await voice.speak(text)
            done.on = true
        }
        return done
    }

    /// Polls in real time: some of these wait out a (short) timeout.
    private func until(
        _ condition: @autoclosure () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting", file: file, line: line)
    }

    func testTheChunksAreSeveral() {
        XCTAssertGreaterThanOrEqual(chunks.count, 3, "the tests below need a remainder to read")
    }

    // MARK: - Kokoro works

    func testKokoroReadsItAndTheAppleVoiceIsNotUsed() async {
        let (voice, kokoro, apple) = rig()
        await voice.speak(text)
        XCTAssertEqual(kokoro.spoken, [chunks])
        XCTAssertEqual(apple.spoken, [])
        XCTAssertEqual(kokoro.stops, 0)
    }

    /// First audio inside the timeout keeps Kokoro reading however long
    /// the rest of it takes.
    func testFirstAudioInTimeCallsOffTheTimeout() async throws {
        let (voice, kokoro, apple) = rig(timeout: .milliseconds(50))
        kokoro.audio = false
        kokoro.holds = true
        let done = start(voice)
        await until(kokoro.spoken.count == 1)
        kokoro.firstAudio()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(kokoro.stops, 0, "stopped after its first audio")
        kokoro.finish()
        await until(done.on)
        XCTAssertEqual(apple.spoken, [])
    }

    // MARK: - Kokoro fails

    /// Down, busy or off the tailnet: nothing in 3 s, so Kokoro is stopped
    /// and the Apple voice reads all of it.
    func testNoFirstAudioInTimeMeansTheAppleVoiceReadsAllOfIt() async {
        let (voice, kokoro, apple) = rig(timeout: .milliseconds(50))
        kokoro.audio = false
        kokoro.holds = true
        let done = start(voice)
        await until(done.on)
        XCTAssertEqual(kokoro.stops, 1)
        XCTAssertEqual(apple.spoken, [text])
    }

    func testAFailureBeforeAnyAudioMeansTheAppleVoiceReadsAllOfIt() async {
        let (voice, kokoro, apple) = rig()
        kokoro.audio = false
        kokoro.result = SpeechFailure(reason: .unavailable, delivered: 0)
        await voice.speak(text)
        XCTAssertEqual(apple.spoken, [text])
    }

    /// What Kokoro delivered is not said again: the Apple voice picks up at
    /// the chunk that failed.
    func testAFailureMidwayMeansTheAppleVoiceReadsTheRest() async {
        let (voice, kokoro, apple) = rig()
        kokoro.result = SpeechFailure(reason: .torn, delivered: 1)
        await voice.speak(text)
        XCTAssertEqual(apple.spoken, [chunks.dropFirst().joined(separator: " ")])
    }

    func testAFailureAfterTheLastChunkHasNothingLeftToRead() async {
        let (voice, kokoro, apple) = rig()
        kokoro.result = SpeechFailure(reason: .torn, delivered: chunks.count)
        await voice.speak(text)
        XCTAssertEqual(apple.spoken, [])
    }

    /// A rotated token or a locked phone: one quick failed request, the
    /// Apple voice reads it, and that is all. No second try at Kokoro, and
    /// the next answer tries it once again, not in a loop.
    func testARejectedOrLockedTokenIsOneTryNotALoop() async {
        for reason in [TTSError.unauthorized, .locked] {
            let (voice, kokoro, apple) = rig()
            kokoro.audio = false
            kokoro.result = SpeechFailure(reason: reason, delivered: 0)
            await voice.speak(text)
            XCTAssertEqual(kokoro.spoken.count, 1, "\(reason)")
            XCTAssertEqual(apple.spoken, [text], "\(reason)")
            await voice.speak(text)
            XCTAssertEqual(kokoro.spoken.count, 2, "\(reason)")
            XCTAssertEqual(apple.spoken.count, 2, "\(reason)")
        }
    }

    func testNothingToSayAsksNobody() async {
        let (voice, kokoro, apple) = rig()
        await voice.speak("  ")
        XCTAssertEqual(kokoro.spoken, [])
        XCTAssertEqual(apple.spoken, [])
    }

    // MARK: - stopping

    /// Cancel before Kokoro's first audio: silence, and no Apple voice
    /// afterwards, not even once the timeout has passed.
    func testStopWhileWaitingForKokoro() async throws {
        let (voice, kokoro, apple) = rig(timeout: .milliseconds(50))
        kokoro.audio = false
        kokoro.holds = true
        let done = start(voice)
        await until(kokoro.spoken.count == 1)
        voice.stop()
        await until(done.on)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(kokoro.stops, 1)
        XCTAssertEqual(apple.spoken, [], "a stopped reading fell back")
    }

    func testStopWhileKokoroReads() async {
        let (voice, kokoro, apple) = rig()
        kokoro.holds = true
        let done = start(voice)
        await until(kokoro.spoken.count == 1)
        voice.stop()
        await until(done.on)
        XCTAssertEqual(kokoro.stops, 1)
        XCTAssertEqual(apple.spoken, [])
    }

    func testStopWhileTheAppleVoiceReadsTheRest() async {
        let (voice, kokoro, apple) = rig()
        kokoro.result = SpeechFailure(reason: .busy, delivered: 1)
        apple.holds = true
        let done = start(voice)
        await until(apple.spoken.count == 1)
        voice.stop()
        await until(done.on)
        XCTAssertEqual(apple.stops, 1)
        XCTAssertEqual(kokoro.stops, 1, "Kokoro's delivered audio may still be playing ahead of it")
    }

    /// The timeout fires into the Apple voice; a stop there ends it too.
    func testStopAfterTheTimeout() async {
        let (voice, kokoro, apple) = rig(timeout: .milliseconds(50))
        kokoro.audio = false
        kokoro.holds = true
        apple.holds = true
        let done = start(voice)
        await until(apple.spoken.count == 1)
        voice.stop()
        await until(done.on)
        XCTAssertEqual(apple.stops, 1)
    }

    // MARK: - the app's own words

    /// "Can't reach the rack." must not be fetched FROM that rack, and must
    /// not wait out the first-audio window after a turn that already failed
    /// slowly.
    func testTheAppsOwnWordsSkipKokoro() async {
        let (voice, kokoro, apple) = rig()
        await voice.say(VoiceSession.micBusy)
        XCTAssertEqual(apple.spoken, [VoiceSession.micBusy])
        XCTAssertEqual(kokoro.spoken, [], "the rack that just failed was asked to say so")
    }

    func testStopWhileSayingTheAppsOwnWords() async {
        let (voice, _, apple) = rig()
        apple.holds = true
        let done = Flag()
        Task {
            await voice.say(VoiceSession.micBusy)
            done.on = true
        }
        await until(apple.spoken.count == 1)
        voice.stop()
        await until(done.on)
        XCTAssertEqual(apple.stops, 1)
    }

    // MARK: - the two voices on one output

    /// THE ONE OUTPUT IS SHARED, so the order things reach it is the whole
    /// hand-over: Kokoro is silenced BEFORE the Apple voice plays a word,
    /// or the two would talk over each other.
    func testTheTimeoutSilencesKokoroBeforeTheAppleVoicePlays() async {
        let output = FakeOutput()
        let hub = FakeKokoro()
        let naps = FakeNaps()
        let kokoro = KokoroVoice(
            output: output, fetch: { hub.fetch($0) }, clock: { 0 },
            nap: { await naps.nap($0) })
        let apple = FakeOutputSpeaker(output: output)
        let voice = FallbackVoice(kokoro: kokoro, apple: apple, timeout: .milliseconds(50))

        let text = text
        Task { await voice.speak(text) }
        await until(hub.asked.count == 1)  // and nothing ever comes back
        await until(apple.spoken.count == 1)

        XCTAssertEqual(output.events, [.stop, .buffer(Int(FakeOutputSpeaker.frames))])
        XCTAssertEqual(apple.spoken, [text])
        naps.wake()
    }

    /// A failure midway is the other way about: what Kokoro delivered is
    /// NOT stopped, and the Apple voice's audio queues up behind it.
    func testAFailureMidwayLeavesKokorosAudioPlayingUnderTheAppleVoice() async {
        let output = FakeOutput()
        let hub = FakeKokoro()
        let naps = FakeNaps()
        let kokoro = KokoroVoice(
            output: output, fetch: { hub.fetch($0) }, clock: { 0 },
            nap: { await naps.nap($0) })
        let apple = FakeOutputSpeaker(output: output)
        let voice = FallbackVoice(kokoro: kokoro, apple: apple, timeout: .seconds(60))

        let text = text
        Task { await voice.speak(text) }
        await until(hub.asked.count == 1)
        hub.send(0, samples: 24_000)
        hub.end(0)
        await until(hub.asked.count == 2)
        hub.fail(1, .torn)
        await until(apple.spoken.count == 1)

        XCTAssertFalse(output.events.contains(.stop), "Kokoro's audio was cut off mid-answer")
        XCTAssertEqual(output.events.last, .buffer(Int(FakeOutputSpeaker.frames)))
        XCTAssertEqual(apple.spoken, [chunks.dropFirst().joined(separator: " ")])
        naps.wake()
    }

    // MARK: - what is being said

    func testSpeakingNowFollowsWhicheverVoiceIsReading() async {
        let (voice, kokoro, apple) = rig()
        kokoro.holds = true
        kokoro.speakingNow = [chunks[0]]
        let done = start(voice)
        await until(kokoro.spoken.count == 1)
        XCTAssertEqual(voice.speakingNow, [chunks[0]])

        kokoro.result = SpeechFailure(reason: .torn, delivered: 1)
        apple.holds = true
        kokoro.finish()
        await until(apple.spoken.count == 1)
        let rest = chunks.dropFirst().joined(separator: " ")
        XCTAssertEqual(voice.speakingNow, [chunks[0], rest], "Kokoro's last chunk may still be playing")

        voice.stop()
        await until(done.on)
        XCTAssertEqual(voice.speakingNow, [])
    }
}
