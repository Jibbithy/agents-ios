// AgentsTests/KokoroVoiceTests.swift
import AVFoundation
import XCTest

@testable import Agents

// MARK: - fakes

/// Takes what a speaker schedules, and plays it as soon as asked: `holds`
/// keeps `drained` waiting until `play()`.
@MainActor final class FakeOutput: SpeechOutput {
    /// What reached the output, in order: one shared output is where two
    /// voices can tread on each other.
    enum Event: Equatable {
        case buffer(Int)
        case stop
    }

    let format = AVAudioFormat(standardFormatWithSampleRate: VoiceOutput.rate, channels: 1)!
    var holds = false
    private(set) var buffers: [[Float]] = []
    private(set) var events: [Event] = []
    private(set) var stops = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var frames: Int { buffers.reduce(0) { $0 + $1.count } }
    var samples: [Float] { buffers.flatMap { $0 } }

    func schedule(_ buffer: AVAudioPCMBuffer) {
        XCTAssertEqual(buffer.format, format)
        let data = buffer.floatChannelData![0]
        buffers.append(Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))))
        events.append(.buffer(Int(buffer.frameLength)))
    }
    func stop() {
        stops += 1
        events.append(.stop)
        play()
    }
    func drained() async {
        guard holds else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    /// Everything scheduled has been heard.
    func play() {
        let waiters = self.waiters
        self.waiters = []
        for waiter in waiters { waiter.resume() }
    }
}

/// Stands in for /api/tts: every request is a stream the test feeds.
@MainActor final class FakeKokoro {
    private(set) var asked: [String] = []
    private(set) var cancelled = 0
    private var pipes: [AsyncThrowingStream<Data, Error>.Continuation] = []

    func fetch(_ text: String) -> AsyncThrowingStream<Data, Error> {
        asked.append(text)
        let (stream, pipe) = AsyncThrowingStream<Data, Error>.makeStream()
        pipe.onTermination = { [weak self] ending in
            guard case .cancelled = ending, let self else { return }
            Task { @MainActor in self.cancelled += 1 }
        }
        pipes.append(pipe)
        return stream
    }

    /// `count` samples of request `i`, each worth its own index / 32768.
    func send(_ i: Int, samples count: Int, from start: Int = 0) {
        var data = Data()
        for n in start..<start + count {
            let v = UInt16(truncatingIfNeeded: n)
            data.append(UInt8(v & 0xFF))
            data.append(UInt8(v >> 8))
        }
        pipes[i].yield(data)
    }
    func send(_ i: Int, bytes: [UInt8]) { pipes[i].yield(Data(bytes)) }
    func end(_ i: Int) { pipes[i].finish() }
    func fail(_ i: Int, _ error: TTSError) { pipes[i].finish(throwing: error) }
}

@MainActor final class ManualClock {
    var now: TimeInterval = 0
}

/// The stall watchdog's waits, under the test's own hand: waking them is
/// time passing.
@MainActor final class FakeNaps {
    private(set) var asked: [TimeInterval] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var sleeping: Int { waiting.count }

    func nap(_ seconds: TimeInterval) async {
        asked.append(seconds)
        await withCheckedContinuation { waiting.append($0) }
    }

    func wake() {
        let waiters = waiting
        waiting = []
        for waiter in waiters { waiter.resume() }
    }
}

/// A voice that plays into the same output the real Apple one does, so a
/// hand-over can be watched in the order it reaches that output.
@MainActor final class FakeOutputSpeaker: Speaking {
    static let frames: AVAudioFrameCount = 2_400

    private let output: FakeOutput
    private(set) var spoken: [String] = []
    private(set) var stops = 0

    init(output: FakeOutput) { self.output = output }

    func speak(_ text: String) async {
        spoken.append(text)
        let buffer = AVAudioPCMBuffer(pcmFormat: output.format, frameCapacity: Self.frames)!
        buffer.frameLength = Self.frames
        output.schedule(buffer)
        await output.drained()
    }
    func stop() {
        stops += 1
        output.stop()
    }
}

/// What one `KokoroVoice.speak` came back with.
@MainActor final class Outcome {
    var returned = false
    var failure: SpeechFailure?
    var firstAudio = 0
}

// MARK: - the decoder and the timeline

final class PCM16LETests: XCTestCase {
    func testLittleEndianSixteenBit() {
        var pcm = PCM16LE()
        XCTAssertEqual(
            pcm.decode(Data([0x00, 0x40, 0xFF, 0x7F, 0x00, 0x80, 0xFF, 0xFF])),
            [0.5, 32_767.0 / 32_768, -1, -1.0 / 32_768])
    }

    /// The hub's pieces are cut wherever the network cuts them: half a
    /// sample waits for the other half, rather than shifting every sample
    /// after it by a byte, which is loud noise.
    func testASampleSplitAcrossPiecesIsPutBackTogether() {
        var pcm = PCM16LE()
        XCTAssertEqual(pcm.decode(Data([0x00])), [])
        XCTAssertEqual(pcm.decode(Data([0x40, 0x00])), [0.5])
        XCTAssertEqual(pcm.decode(Data()), [])
        XCTAssertEqual(pcm.decode(Data([0xC0, 0x00, 0x20])), [-0.5, 0.25])
    }
}

final class PlayoutTimelineTests: XCTestCase {
    func testNothingScheduledIsNothingPlaying() {
        XCTAssertNil(PlayoutTimeline().chunk(at: 5))
    }

    /// A chunk scheduled while another plays starts where that one ends.
    func testAChunkPlaysAfterTheOneBeforeIt() {
        var timeline = PlayoutTimeline()
        timeline.scheduled(chunk: 0, seconds: 0.1, at: 0)
        timeline.scheduled(chunk: 0, seconds: 0.5, at: 0)
        XCTAssertEqual(timeline.scheduled(chunk: 1, seconds: 1, at: 0.3), 0)
        XCTAssertEqual(timeline.chunk(at: 0.5), 0)
        XCTAssertEqual(timeline.chunk(at: 0.7), 1)
        XCTAssertEqual(timeline.end, 1.6, accuracy: 1e-9)
    }

    /// Once the output has run dry, the next chunk starts when it arrives,
    /// and the silence before it is what the device check wants to see.
    func testARunDryOutputStartsTheNextChunkWhenItArrives() {
        var timeline = PlayoutTimeline()
        timeline.scheduled(chunk: 0, seconds: 1, at: 0)
        XCTAssertEqual(timeline.scheduled(chunk: 1, seconds: 1, at: 1.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(timeline.chunk(at: 1.2), 0, "the last one heard, while nothing plays")
        XCTAssertEqual(timeline.chunk(at: 1.6), 1)
    }
}

// MARK: - KokoroVoice

@MainActor
final class KokoroVoiceTests: XCTestCase {
    private lazy var output = FakeOutput()
    private lazy var kokoro = FakeKokoro()
    private lazy var clock = ManualClock()
    private lazy var naps = FakeNaps()

    private lazy var voice: KokoroVoice = {
        let kokoro = kokoro
        let clock = clock
        let naps = naps
        return KokoroVoice(
            output: output, fetch: { kokoro.fetch($0) }, clock: { clock.now },
            nap: { await naps.nap($0) })
    }()

    /// Nothing is left waiting on a nap that will never come.
    override func tearDown() async throws {
        naps.wake()
        try await super.tearDown()
    }

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

    /// Starts reading `chunks`, and keeps what comes back.
    private func start(_ chunks: [String]) -> Outcome {
        let outcome = Outcome()
        let voice = voice
        Task {
            outcome.failure = await voice.speak(chunks, onFirstAudio: { outcome.firstAudio += 1 })
            outcome.returned = true
        }
        return outcome
    }

    /// ONE REQUEST AT A TIME, the next as soon as the one before has all
    /// arrived: while it plays, not after. Two at once would share atlas's
    /// two CPUs and both come later.
    func testAsksForEachChunkOnceTheOneBeforeHasArrived() async {
        let outcome = start(["One.", "Two two.", "Three three three."])
        await until(kokoro.asked == ["One."])

        kokoro.send(0, samples: 3_000)
        await until(output.frames == 2_400)
        await settle()
        XCTAssertEqual(kokoro.asked, ["One."], "asked for the next before this one had arrived")

        kokoro.end(0)
        await until(kokoro.asked.count == 2)
        XCTAssertEqual(output.frames, 3_000, "the rest of the first, flushed at its end")
        kokoro.send(1, samples: 100)
        kokoro.end(1)
        await until(kokoro.asked.count == 3)
        kokoro.send(2, samples: 100)
        kokoro.end(2)
        await until(outcome.returned)

        XCTAssertEqual(kokoro.asked, ["One.", "Two two.", "Three three three."])
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(output.frames, 3_200)
        XCTAssertEqual(output.stops, 0)
    }

    /// Every sample, in order, in few buffers: a tenth of a second first so
    /// Atlas starts at once, then half-seconds (`SpeechBatcher`).
    func testPlaysEverySampleInOrderInBigBuffers() async {
        let outcome = start(["One."])
        await until(kokoro.asked.count == 1)
        for piece in 0..<10 { kokoro.send(0, samples: 2_400, from: piece * 2_400) }
        kokoro.end(0)
        await until(outcome.returned)
        XCTAssertEqual(output.buffers.map(\.count), [2_400, 12_000, 9_600])
        XCTAssertEqual(output.samples, (0..<24_000).map { Float(Int16(truncatingIfNeeded: $0)) / 32_768 })
    }

    func testASampleSplitAcrossPiecesPlaysWhole() async {
        let outcome = start(["One."])
        await until(kokoro.asked.count == 1)
        kokoro.send(0, bytes: [0x00, 0x40, 0x00])
        kokoro.send(0, bytes: [0xC0])
        kokoro.end(0)
        await until(outcome.returned)
        XCTAssertEqual(output.samples, [0.5, -0.5])
    }

    func testFirstAudioIsToldOnceWhenItIsScheduled() async {
        let outcome = start(["One.", "Two."])
        await until(kokoro.asked.count == 1)
        kokoro.send(0, samples: 1_000)
        await settle()
        XCTAssertEqual(outcome.firstAudio, 0, "nothing has been scheduled yet")
        kokoro.send(0, samples: 2_000)
        await until(outcome.firstAudio == 1)
        XCTAssertEqual(output.frames, 2_400)
        kokoro.end(0)
        await until(kokoro.asked.count == 2)
        kokoro.send(1, samples: 20_000)
        kokoro.end(1)
        await until(outcome.returned)
        XCTAssertEqual(outcome.firstAudio, 1)
    }

    /// `speak` is over when Atlas has stopped talking, not when the last
    /// byte arrived: the session opens the mic for the next question then.
    func testReturnsOnlyOnceTheLastOfItHasPlayed() async {
        output.holds = true
        let outcome = start(["One."])
        await until(kokoro.asked.count == 1)
        kokoro.send(0, samples: 100)
        kokoro.end(0)
        await settle()
        XCTAssertFalse(outcome.returned)
        output.play()
        await until(outcome.returned)
        XCTAssertNil(outcome.failure)
    }

    // MARK: - failing

    /// THE REST IS THE FALLBACK'S TO SAY: which chunks got to the output
    /// whole, and they play on rather than being cut off.
    func testAFailureMidwaySaysHowFarItGot() async {
        let outcome = start(["One.", "Two two.", "Three three three."])
        await until(kokoro.asked.count == 1)
        kokoro.send(0, samples: 3_000)
        kokoro.end(0)
        await until(kokoro.asked.count == 2)
        kokoro.send(1, samples: 3_000)
        kokoro.fail(1, .torn)
        await until(outcome.returned)

        XCTAssertEqual(outcome.failure, SpeechFailure(reason: .torn, delivered: 1))
        XCTAssertEqual(kokoro.asked, ["One.", "Two two."], "asked for more after a failure")
        XCTAssertEqual(output.stops, 0, "what did arrive was cut off")
        // A batch of the torn chunk that was already scheduled plays; what
        // was still being gathered is dropped. The Apple voice says that
        // chunk again from its start either way.
        XCTAssertEqual(output.frames, 3_000 + 2_400)
    }

    func testAFailureBeforeAnyAudio() async {
        let outcome = start(["One.", "Two."])
        await until(kokoro.asked.count == 1)
        kokoro.fail(0, .busy)
        await until(outcome.returned)
        XCTAssertEqual(outcome.failure, SpeechFailure(reason: .busy, delivered: 0))
        XCTAssertEqual(outcome.firstAudio, 0)
        XCTAssertEqual(output.frames, 0)
    }

    /// A 200 with no audio in it is not speech: the chunk would be lost.
    func testAChunkWithNoAudioIsAFailure() async {
        let outcome = start(["One.", "Two."])
        await until(kokoro.asked.count == 1)
        kokoro.end(0)
        await until(outcome.returned)
        XCTAssertEqual(outcome.failure, SpeechFailure(reason: .torn, delivered: 0))
    }

    // MARK: - stopping

    /// Cancel or a barge-in: silence now, `speak` back at once, and the
    /// request cancelled, so atlas stops synthesising for nobody.
    func testStopSilencesReturnsAndCancelsTheRequest() async {
        let outcome = start(["One.", "Two."])
        await until(kokoro.asked.count == 1)
        kokoro.send(0, samples: 3_000)
        await until(output.frames == 2_400)

        voice.stop()
        await until(outcome.returned)
        XCTAssertNil(outcome.failure, "a stop is not a failure: nothing is to be read after it")
        XCTAssertEqual(output.stops, 1)
        await until(kokoro.cancelled == 1)

        kokoro.send(0, samples: 20_000)
        await settle()
        XCTAssertEqual(output.frames, 2_400, "audio from a stopped reading was played")
        XCTAssertEqual(kokoro.asked, ["One."])
    }

    func testStopWhileTheLastOfItPlays() async {
        output.holds = true
        let outcome = start(["One."])
        await until(kokoro.asked.count == 1)
        kokoro.send(0, samples: 100)
        kokoro.end(0)
        await settle()
        voice.stop()
        await until(outcome.returned)
        XCTAssertEqual(output.stops, 1)
    }

    /// After a failure midway its audio is still playing while the Apple
    /// voice takes over. A stop then must silence it too.
    func testStopAfterAFailureSilencesWhatIsStillPlaying() async {
        let outcome = start(["One.", "Two."])
        await until(kokoro.asked.count == 1)
        kokoro.send(0, samples: 3_000)
        kokoro.end(0)
        await until(kokoro.asked.count == 2)
        kokoro.fail(1, .unavailable)
        await until(outcome.returned)
        XCTAssertEqual(output.stops, 0)
        voice.stop()
        XCTAssertEqual(output.stops, 1)
    }

    func testStopWithNothingBeingReadDoesNotTouchTheOutput() {
        voice.stop()
        XCTAssertEqual(output.stops, 0, "the output is shared: this may be the Apple voice's reading")
    }

    // MARK: - going quiet

    /// A phone walking out of Wi-Fi at chunk 2 of 3, or Kokoro wedging:
    /// nothing playing, and nothing arriving. Waiting the request's own
    /// timeout out would be 12 s of silence with the mic open.
    func testAReadingGoneQuietGivesUpSoTheRestCanBeSaid() async {
        let outcome = start(["One.", "Two two.", "Three."])
        await until(kokoro.asked.count == 1)
        kokoro.send(0, samples: 24_000)  // one second of audio
        kokoro.end(0)
        await until(kokoro.asked.count == 2)
        await until(naps.sleeping == 1)

        clock.now = 10  // that second finished long ago
        naps.wake()
        await until(outcome.returned)

        XCTAssertEqual(outcome.failure, SpeechFailure(reason: .stalled, delivered: 1))
        XCTAssertEqual(output.stops, 0, "what had already played was cut off")
        await until(kokoro.cancelled == 1)
    }

    /// Audio still playing is not a stall, however long the next chunk takes.
    func testAudioStillPlayingIsNotAStall() async {
        let outcome = start(["One.", "Two two.", "Three."])
        await until(kokoro.asked.count == 1)
        kokoro.send(0, samples: 24_000)
        kokoro.end(0)
        await until(kokoro.asked.count == 2)
        await until(naps.sleeping == 1)

        clock.now = 0.5  // half a second in
        naps.wake()
        await until(naps.asked.count == 2)
        XCTAssertFalse(outcome.returned, "it gave up while the audio was still playing")
    }

    /// A slow trickle is a live connection, and gets another window before
    /// the reading is given up.
    func testATrickleGetsAnotherWindow() async {
        let outcome = start(["One.", "Two two.", "Three."])
        await until(kokoro.asked.count == 1)
        kokoro.send(0, samples: 24_000)
        kokoro.end(0)
        await until(kokoro.asked.count == 2)
        await until(naps.sleeping == 1)

        clock.now = 10
        kokoro.send(1, samples: 100)  // too little to play, but it is arriving
        naps.wake()
        await until(naps.asked.count == 2)
        XCTAssertFalse(outcome.returned)

        naps.wake()  // and now nothing more comes
        await until(outcome.returned)
        XCTAssertEqual(outcome.failure, SpeechFailure(reason: .stalled, delivered: 1))
    }

    // MARK: - one reading at a time

    /// A second reading takes the voice over: the first returns at once, its
    /// audio is silenced, and nothing its request delivers afterwards is
    /// ever played or counted against the new one.
    func testASecondReadingTakesOverFromOneStillArriving() async {
        let first = start(["One.", "Two."])
        await until(kokoro.asked.count == 1)
        kokoro.send(0, samples: 3_000)
        await until(output.frames == 2_400)

        let second = start(["Three."])
        await until(first.returned)
        XCTAssertNil(first.failure, "taking over is not a failure to fall back from")
        XCTAssertEqual(output.stops, 1)
        await until(kokoro.asked.count == 2)

        kokoro.send(0, samples: 24_000)  // the old request, still going
        kokoro.end(0)
        await settle()
        XCTAssertEqual(output.frames, 2_400, "the old reading played into the new one")

        kokoro.send(1, samples: 2_400)
        kokoro.end(1)
        await until(second.returned)
        XCTAssertNil(second.failure)
        XCTAssertEqual(output.frames, 2_400 + 2_400)
        XCTAssertEqual(kokoro.asked, ["One.", "Three."])
    }

    // MARK: - what is being said

    /// For the echo guard (A3): the chunk playing and the one before it, by
    /// when each was scheduled to play.
    func testSpeakingNowIsTheChunkPlayingAndTheOneBefore() async {
        let outcome = start(["One.", "Two two.", "Three."])
        XCTAssertEqual(voice.speakingNow, [], "nothing is playing yet")
        await until(kokoro.asked.count == 1)
        kokoro.send(0, samples: 24_000)  // one second
        kokoro.end(0)
        await until(kokoro.asked.count == 2)
        XCTAssertEqual(voice.speakingNow, ["One."])

        clock.now = 0.5
        kokoro.send(1, samples: 24_000)
        kokoro.end(1)
        await until(kokoro.asked.count == 3)
        XCTAssertEqual(voice.speakingNow, ["One."], "the second is queued behind the first")
        clock.now = 1.2
        XCTAssertEqual(voice.speakingNow, ["One.", "Two two."])

        clock.now = 2.5
        XCTAssertEqual(voice.speakingNow, ["One.", "Two two."], "run dry, waiting for the third")
        kokoro.send(2, samples: 2_400)
        kokoro.end(2)
        await until(outcome.returned)
        XCTAssertEqual(voice.speakingNow, [], "it has all been said")
    }

    func testSpeakingNowIsEmptyAfterAStop() async {
        _ = start(["One."])
        await until(kokoro.asked.count == 1)
        kokoro.send(0, samples: 3_000)
        await until(output.frames > 0)
        XCTAssertEqual(voice.speakingNow, ["One."])
        voice.stop()
        XCTAssertEqual(voice.speakingNow, [])
    }
}
