// AgentsTests/AppleVoiceTests.swift
import AVFoundation
import XCTest

@testable import Agents

/// The synthesiser's side of a reading: what it writes, and how a reading
/// ENDS. The header does not promise the empty buffer that says "that was
/// all", so the end can come from three places - that buffer, the
/// synthesiser's delegate, or the watchdog - and a reading that ended twice,
/// or never, holds the session in `.speaking` with the mic open.
final class AppleVoiceTests: XCTestCase {

    private func format() throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: VoiceOutput.rate, channels: 1))
    }

    /// What a voice writes: 22.05 kHz mono float, in small buffers.
    private func written(_ frames: Int) throws -> AVAudioPCMBuffer {
        let voice = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: voice, frameCapacity: AVAudioFrameCount(max(frames, 1))))
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    /// What came out of the writer: the kind of each piece, and how many
    /// frames of speech in all. The frame counts of each are the resampler's
    /// business, not this test's.
    private func pieces(_ stream: AsyncStream<WrittenSpeech>) async -> (kinds: [String], frames: Int) {
        var kinds: [String] = []
        var frames = 0
        for await piece in stream {
            switch piece {
            case .audio(let chunk):
                kinds.append("audio")
                frames += Int(chunk.buffer.frameLength)
            case .end:
                kinds.append("end")
            }
        }
        return (kinds, frames)
    }

    /// The speech comes out batched, and the empty buffer ends it once.
    func testTheEmptyBufferEndsTheReading() async throws {
        let (stream, sink) = AsyncStream.makeStream(of: WrittenSpeech.self)
        let writer = SpeechWriter(to: try format(), into: sink, now: { 10 })
        for _ in 0..<12 { writer.write(try written(256)) }  // 3_072 frames at 22.05 kHz
        XCTAssertFalse(writer.hasEnded)
        writer.write(try written(0))
        XCTAssertTrue(writer.hasEnded)
        XCTAssertEqual(writer.lastWrite, 10)
        let seen = await pieces(stream)
        XCTAssertEqual(seen.kinds, ["audio", "audio", "end"], "a full batch, the rest, then the end")
        XCTAssertEqual(Double(seen.frames), 3_072 * VoiceOutput.rate / 22_050, accuracy: 40)
    }

    /// A second empty buffer (the Simulator sends two), the delegate's
    /// didFinish and the watchdog all land on the same reading. It ends ONCE.
    func testAReadingEndsOnlyOnce() async throws {
        let (stream, sink) = AsyncStream.makeStream(of: WrittenSpeech.self)
        let writer = SpeechWriter(to: try format(), into: sink, now: { 1 })
        writer.write(try written(2_205))
        writer.write(try written(0))
        writer.write(try written(0))
        writer.end()
        writer.end()
        let seen = await pieces(stream)
        XCTAssertEqual(seen.kinds.filter { $0 == "end" }.count, 1)
    }

    /// The end from somewhere other than the empty buffer still says
    /// whatever was batched but not yet handed over: up to half a second of
    /// speech, which would otherwise be cut off the answer.
    func testEndingFromOutsideStillSaysTheLastOfIt() async throws {
        let (stream, sink) = AsyncStream.makeStream(of: WrittenSpeech.self)
        let writer = SpeechWriter(to: try format(), into: sink, now: { 1 })
        writer.write(try written(2_205))
        writer.end()
        let seen = await pieces(stream)
        XCTAssertEqual(seen.kinds, ["audio", "end"])
        XCTAssertEqual(Double(seen.frames), 2_400, accuracy: 40, "a tenth of a second, kept")
    }

    /// Anything the synthesiser writes after the end is ignored: the reading
    /// is over, and its audio is no longer wanted.
    func testWritesAfterTheEndAreIgnored() async throws {
        let (stream, sink) = AsyncStream.makeStream(of: WrittenSpeech.self)
        let writer = SpeechWriter(to: try format(), into: sink, now: { 1 })
        writer.end()
        writer.write(try written(2_205))
        writer.write(try written(0))
        let seen = await pieces(stream)
        XCTAssertEqual(seen.kinds, ["end"])
        XCTAssertEqual(seen.frames, 0)
    }

    // MARK: - the watchdog

    /// The synthesiser writes far faster than the speech plays - a whole
    /// answer in a few tens of milliseconds - so a long silence with nothing
    /// left to play means the end is never coming.
    func testTheWatchdogGivesUpOnASilentSynthesiser() {
        // Nothing written yet: a voice being loaded gets longer.
        XCTAssertFalse(WriteWatchdog.gaveUp(now: 4, started: 0, lastWrite: nil, ended: false, drained: true))
        XCTAssertTrue(WriteWatchdog.gaveUp(now: 6, started: 0, lastWrite: nil, ended: false, drained: true))
        // Writing began, then stopped short of the end.
        XCTAssertFalse(WriteWatchdog.gaveUp(now: 6, started: 0, lastWrite: 5, ended: false, drained: true))
        XCTAssertTrue(WriteWatchdog.gaveUp(now: 7.5, started: 0, lastWrite: 5, ended: false, drained: true))
    }

    /// Never while there is still speech to play: a long answer, or Kokoro's
    /// audio still ahead of the Apple voice on the same output.
    func testTheWatchdogWaitsWhileAnythingIsStillPlaying() {
        XCTAssertFalse(WriteWatchdog.gaveUp(now: 60, started: 0, lastWrite: 1, ended: false, drained: false))
        XCTAssertFalse(WriteWatchdog.gaveUp(now: 60, started: 0, lastWrite: nil, ended: false, drained: false))
    }

    /// And never on a reading that has already ended - which every reading
    /// does long before its speech has finished playing.
    func testTheWatchdogLeavesAnEndedReadingAlone() {
        XCTAssertFalse(WriteWatchdog.gaveUp(now: 600, started: 0, lastWrite: 1, ended: true, drained: true))
    }
}
