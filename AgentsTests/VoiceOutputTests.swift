// AgentsTests/VoiceOutputTests.swift
import AVFoundation
import XCTest

@testable import Agents

/// The bookkeeping, routing, batching and conversion under `VoiceOutput`. A
/// ledger off by one leaves a speak waiting forever with the mic open, or
/// returns it while Atlas is still talking; a buffer sent to the wrong place
/// is a second I/O unit, or silence; a batcher that drops or reorders
/// samples is heard; a converter short of room holds audio back a buffer late.
final class VoiceOutputTests: XCTestCase {

    // MARK: - the ledger

    /// Buffers are counted by epoch, and whoever waits in `drained` waits
    /// here. The epoch tells a callback from before a stop - or from an
    /// engine that was thrown away - from one for what was scheduled after.
    func testNothingScheduledIsDrained() {
        var ledger = PlayoutLedger<String>()
        XCTAssertTrue(ledger.isDrained)
        XCTAssertEqual(ledger.wait("now"), "now", "nothing to wait for")
        XCTAssertEqual(ledger.waiting, 0)
    }

    func testDrainedOnlyWhenTheLastBufferIsHeard() {
        var ledger = PlayoutLedger<String>()
        let first = ledger.scheduled()
        let second = ledger.scheduled()
        XCTAssertNil(ledger.wait("end"))
        XCTAssertEqual(ledger.played(first), [])
        XCTAssertFalse(ledger.isDrained)
        XCTAssertEqual(ledger.played(second), ["end"])
        XCTAssertTrue(ledger.isDrained)
        XCTAssertEqual(ledger.waiting, 0, "a waiter is woken once")
    }

    /// Several waiters at once: the Apple voice waiting on its own speech
    /// while Kokoro's is still ahead of it on the same output.
    func testEveryWaiterIsWokenTogether() {
        var ledger = PlayoutLedger<String>()
        let buffer = ledger.scheduled()
        XCTAssertNil(ledger.wait("kokoro"))
        XCTAssertNil(ledger.wait("apple"))
        XCTAssertEqual(ledger.played(buffer), ["kokoro", "apple"])
    }

    /// A stop, and an engine thrown away: everything scheduled is gone, and
    /// whoever was waiting is woken rather than left waiting on callbacks
    /// that will never come.
    func testADropWakesEveryWaiter() {
        var ledger = PlayoutLedger<String>()
        _ = ledger.scheduled()
        XCTAssertNil(ledger.wait("speak"))
        XCTAssertEqual(ledger.dropAll(), ["speak"])
        XCTAssertTrue(ledger.isDrained)
        XCTAssertEqual(ledger.wait("after"), "after", "and nothing to wait for after it")
        XCTAssertEqual(ledger.dropAll(), [], "no one left to wake")
    }

    /// A stopped player calls back for everything it dropped. Those
    /// callbacks must not count against what is scheduled after the stop.
    func testCallbacksFromBeforeADropAreIgnored() {
        var ledger = PlayoutLedger<String>()
        let old = ledger.scheduled()
        _ = ledger.scheduled()
        _ = ledger.dropAll()
        let new = ledger.scheduled()
        XCTAssertNil(ledger.wait("end"))
        XCTAssertEqual(ledger.played(old), [])
        XCTAssertEqual(ledger.played(old), [])
        XCTAssertFalse(ledger.isDrained, "the new buffer is still to play")
        XCTAssertEqual(ledger.played(new), ["end"])
    }

    /// More callbacks than buffers never takes the count below zero.
    func testExtraCallbacksDoNothing() {
        var ledger = PlayoutLedger<String>()
        let epoch = ledger.scheduled()
        XCTAssertEqual(ledger.played(epoch), [])
        XCTAssertEqual(ledger.played(epoch), [])
        XCTAssertEqual(ledger.outstanding, 0)
    }

    // MARK: - where a buffer goes

    /// ONE I/O unit for the voice: the mic's engine while there is one, and
    /// an engine of its own only when there is NONE - the mic failed, and
    /// "Mic busy." still has to be said. An engine that is merely stopped (a
    /// route change, a call) plays nothing: a second engine there would be a
    /// second I/O unit, without echo cancellation, and every chunk Kokoro
    /// streams in would land on it.
    func testWhereABufferGoes() {
        XCTAssertEqual(VoiceOutput.route(open: true, host: .running), .play)
        XCTAssertEqual(VoiceOutput.route(open: true, host: .gone), .ownEngine)
        XCTAssertEqual(VoiceOutput.route(open: true, host: .stopped), .drop)
        XCTAssertEqual(VoiceOutput.route(open: true, host: .silent), .drop)
    }

    /// Nothing plays outside a voice session. A chunk landing late - the hub
    /// answering after the session ended - would otherwise start an engine
    /// and switch the ducking session back on, with nobody left to switch it
    /// off again.
    func testNothingPlaysAfterTheSessionIsOver() {
        for host in [VoiceOutput.Host.gone, .running, .stopped, .silent] {
            XCTAssertEqual(VoiceOutput.route(open: false, host: host), .drop)
        }
    }

    /// An output that reports no rate or no channels has not come up: the
    /// audio server timed out, or there is no route. Connecting the main
    /// mixer to it then raises an exception Swift cannot catch.
    func testAnEmptyOutputFormatIsNotPlayable() throws {
        XCTAssertTrue(VoiceOutput.canPlay(try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))))
        XCTAssertTrue(VoiceOutput.canPlay(try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: VoiceOutput.rate, channels: 1))))
        XCTAssertFalse(VoiceOutput.canPlay(AVAudioFormat()), "no rate, no channels")
    }

    // MARK: - the batcher

    private func ramp(from start: Int, count: Int, in format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<count { samples[i] = Float(start + i) }
        return buffer
    }

    /// The synthesiser's 256-frame buffers come out as a tenth of a second,
    /// then half-seconds, then the rest at the end: every sample, in order.
    func testBatchesSmallBuffersIntoFewBigOnes() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: VoiceOutput.rate, channels: 1))
        let batcher = SpeechBatcher(format: format)
        var chunks: [AVAudioPCMBuffer] = []
        var sent = 0
        while sent < 30_000 {
            chunks += batcher.append(try ramp(from: sent, count: 256, in: format))
            sent += 256
        }
        chunks += [batcher.flush()].compactMap { $0 }
        XCTAssertEqual(chunks.map(\.frameLength), [2_400, 12_000, 12_000, 3_808])  // 30_208 in all
        var next: Float = 0
        for chunk in chunks {
            let samples = try XCTUnwrap(chunk.floatChannelData)[0]
            for i in 0..<Int(chunk.frameLength) {
                XCTAssertEqual(samples[i], next)
                next += 1
            }
        }
        XCTAssertNil(batcher.flush(), "nothing left after a flush")
    }

    /// One buffer bigger than a chunk fills several.
    func testABigBufferFillsSeveralChunks() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: VoiceOutput.rate, channels: 1))
        let batcher = SpeechBatcher(format: format)
        let chunks = batcher.append(try ramp(from: 0, count: 30_000, in: format))
        XCTAssertEqual(chunks.map(\.frameLength), [2_400, 12_000, 12_000])
        XCTAssertEqual(batcher.flush()?.frameLength, 3_600)
    }

    func testABufferInAnotherFormatIsNotBatched() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: VoiceOutput.rate, channels: 1))
        let other = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let batcher = SpeechBatcher(format: format)
        XCTAssertEqual(batcher.append(try ramp(from: 0, count: 5_000, in: other)).count, 0)
        XCTAssertNil(batcher.flush())
    }

    // MARK: - the converter

    func testConverterCapacity() {
        XCTAssertEqual(OutputConverter.capacity(frames: 1_024, from: 22_050, to: 24_000), 1_123)  // 1114.6 → 1115
        XCTAssertEqual(OutputConverter.capacity(frames: 1_024, from: 24_000, to: 24_000), 1_032)
        XCTAssertEqual(OutputConverter.capacity(frames: 4_800, from: 48_000, to: 24_000), 2_408)
        XCTAssertEqual(OutputConverter.capacity(frames: 0, from: 22_050, to: 24_000), 8)
    }

    /// What most Apple voices write: 22.05 kHz mono Int16. Out comes 24 kHz
    /// mono float, about as long, and never a buffer the player would refuse.
    func testConvertsSynthesiserSpeechToTheOutputFormat() throws {
        let target = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: VoiceOutput.rate, channels: 1))
        let source = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 22_050,
                channels: 1, interleaved: true))
        let converter = OutputConverter(to: target)
        var total = 0
        // Several buffers through ONE converter, as an utterance's are.
        for _ in 0..<10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 2_205))
            buffer.frameLength = 2_205
            let samples = try XCTUnwrap(buffer.int16ChannelData)[0]
            for i in 0..<2_205 { samples[i] = Int16(8_000 * sin(Double(i) * 0.1)) }
            let out = try XCTUnwrap(converter.convert(buffer))
            XCTAssertEqual(out.format, target)
            total += Int(out.frameLength)
        }
        // A second of speech, less what the resampler still holds.
        XCTAssertEqual(Double(total), 24_000, accuracy: 100)
    }

    /// A buffer already in the output format comes back as a copy: the
    /// synthesiser may reuse its own once the callback has returned.
    func testABufferAlreadyInFormatIsCopied() throws {
        let target = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: VoiceOutput.rate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 480))
        buffer.frameLength = 480
        let input = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<480 { input[i] = Float(i) / 480 }
        let out = try XCTUnwrap(OutputConverter(to: target).convert(buffer))
        XCTAssertFalse(out === buffer)
        XCTAssertEqual(out.frameLength, 480)
        let copied = try XCTUnwrap(out.floatChannelData)[0]
        XCTAssertEqual(copied[240], input[240], accuracy: 1e-6)
    }
}
