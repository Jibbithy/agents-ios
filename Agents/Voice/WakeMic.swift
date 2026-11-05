// Agents/Voice/WakeMic.swift
import AVFoundation
import Foundation
import LiveKitWakeWord
import os

/// The mic "Hey Atlas" listens on, and the scoring behind it. OURS, NOT THE
/// PACKAGE'S: only `WakeWordModel` (and the mel and embedding models bundled
/// with it) comes from livekit-wakeword.
///
/// BECAUSE OF THE MUSIC. The package's listener sets up a session that cannot
/// mix with other audio, so arming it stops Spotify. Music started again - from
/// the wheel, from CarPlay - interrupts it in turn, with no `.ended` to follow,
/// and it goes deaf with the toggle still on; and every question's end, which
/// re-arms it, stops the music again. On a car mount that is the whole use
/// case gone. This one is MIXABLE, and plays nothing.
///
/// A2DP, NOT HFP, while armed: HFP would hold the AirPods or the car in
/// call-quality mode for the whole drive, just to be ready for a question.
/// The question itself does switch to HFP, for the AirPods' mic - that is
/// `AudioSessionVoice`, and it ducks rather than mixes. No voice processing
/// either: it ducks other audio.
@MainActor
final class WakeMic {
    /// One score at or over the threshold, then the stream ends with the run.
    /// THE FIRST HIT ENDS THE SCORING, which is the whole debounce: the next
    /// run needs two fresh seconds of audio before it can score at all.
    let hits: AsyncStream<Float>

    private let hitSink: AsyncStream<Float>.Continuation
    /// Mic → scorer. BOUNDED, newest kept: a predict running slow drops audio
    /// rather than queueing it without limit behind itself.
    private let feed: AsyncStream<[Int16]>.Continuation
    private let chunks: AsyncStream<[Int16]>
    private let model: WakeWordModel
    private let threshold: Float
    /// Told once, at the run's first good score: the mic and the model both
    /// work. HeyAtlas starts its give-up backoff over on it.
    private let onScoring: @MainActor @Sendable () -> Void

    /// A FRESH ONE EVERY TIME THE MIC STARTS, for the reason on
    /// `AudioSessionVoice.engine`: one that ran before a route change can go
    /// on reporting the old format, and a tap in the wrong format raises an
    /// exception Swift cannot catch.
    private var engine: AVAudioEngine?
    private var scorer: Task<Void, Never>?
    private var changes: Task<Void, Never>?
    private var retry: Task<Void, Never>?

    init(model: WakeWordModel, threshold: Float, onScoring: @escaping @MainActor @Sendable () -> Void) {
        self.model = model
        self.threshold = threshold
        self.onScoring = onScoring
        (hits, hitSink) = AsyncStream.makeStream(of: Float.self)
        (chunks, feed) = AsyncStream.makeStream(of: [Int16].self, bufferingPolicy: .bufferingNewest(16))
    }

    /// Opens the mic and starts scoring. After a throw, `stop` still undoes
    /// whatever did start.
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord, mode: .default,
            options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)
        let (chunks, model, threshold, hits, onScoring) = (chunks, model, threshold, hitSink, onScoring)
        // OFF THE MAIN ACTOR: a predict is milliseconds of CoreML, every 80.
        // `.utility`, for the battery over a long drive; a wake word a few
        // milliseconds later is still a wake word.
        scorer = Task.detached(priority: .utility) {
            await Self.score(chunks, with: model, threshold: threshold, hits: hits, onScoring: onScoring)
        }
        try run()
    }

    /// Closes the mic, and returns only once it is closed and the session is
    /// off. WAITS FOR THE SCORER TO END: the next run scores on the same
    /// model, and two predicts at once on one model are not allowed.
    func stop() async {
        retry?.cancel()
        retry = nil
        changes?.cancel()
        changes = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        feed.finish()
        scorer?.cancel()
        await scorer?.value
        scorer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        hitSink.finish()
    }

    /// Taps a fresh engine. Watched before it starts, so a change that lands
    /// while it is starting is not missed.
    private func run() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        watchChanges(of: engine)
        try Self.start(engine, into: feed)
    }

    /// AN ENGINE STOPS ITSELF when its input changes - AirPods or the car
    /// connecting - and posts this. The same restart as `AudioSessionVoice`'s:
    /// one still running rode the change out, and a fresh engine whose own
    /// start posts a change must not restart itself forever.
    private func restart() {
        guard let old = engine, !old.isRunning else { return }
        changes?.cancel()
        changes = nil
        old.stop()
        old.inputNode.removeTap(onBus: 0)
        do { try run() } catch { retryOnce() }
    }

    /// One more try half a second on, for a route still settling. If that
    /// fails too, THE RUN ENDS rather than sitting deaf with the toggle on:
    /// HeyAtlas starts a fresh one at the next scene or session change.
    private func retryOnce() {
        retry?.cancel()
        let failed = engine
        retry = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, let failed, self.engine === failed else { return }
            do { try self.run() } catch {
                Logger.voice.error("Hey Atlas: the mic would not come back after a route change")
                self.hitSink.finish()
            }
        }
    }

    private func watchChanges(of engine: AVAudioEngine) {
        changes?.cancel()
        let notes = NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange, object: engine)
        changes = Task { [weak self] in
            for await _ in notes {
                guard !Task.isCancelled else { return }
                self?.restart()
            }
        }
    }

    /// Taps the input and starts the engine, with `AudioSessionVoice.start`'s
    /// checks against the hardware's format: no input, or a rate that is not
    /// the hardware's, is a tap that crashes.
    private static func start(_ engine: AVAudioEngine, into feed: AsyncStream<[Int16]>.Continuation) throws {
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard hardware.channelCount > 0, hardware.sampleRate > 0,
            format.sampleRate == hardware.sampleRate,
            let converter = WakeConverter(from: format)
        else { throw VoiceError.micBusy }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap(converter, into: feed))
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// NONISOLATED ON PURPOSE, as `AudioSessionVoice.tap` is: the engine calls
    /// it on a real-time audio thread, where a main-actor closure traps.
    nonisolated private static func tap(
        _ converter: WakeConverter,
        into feed: AsyncStream<[Int16]>.Continuation
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if let samples = converter.convert(buffer) { feed.yield(samples) }
        }
    }

    /// Scores the last two seconds every 80 ms until a hit, or until the
    /// feed ends. Logs, at `.notice` so they survive on the phone, what Task
    /// 17 tunes the threshold from: the peak score every two seconds, below
    /// the threshold too, and each hit's score. And, once a run, the first
    /// predict that failed - a classifier with the wrong tensor names loads
    /// fine and then fails every predict - or else that scoring works.
    nonisolated private static func score(
        _ chunks: AsyncStream<[Int16]>, with model: WakeWordModel,
        threshold: Float, hits: AsyncStream<Float>.Continuation,
        onScoring: @MainActor @Sendable () -> Void
    ) async {
        var window = WakeWindow()
        var peak = WakePeak(every: WakeWindow.scoresPerTwoSeconds)
        var scored = false
        var failed = false
        for await chunk in chunks {
            // STOPPED MEANS STOPPED. A stream still hands over what it had
            // buffered after it was cancelled - up to sixteen chunks, four
            // predicts - and `stop` is waiting on this, with a question's
            // mic waiting on `stop`.
            if Task.isCancelled { return }
            guard let audio = window.append(chunk) else { continue }
            let score: Float
            do {
                score = try model.predict(audio).values.max() ?? 0
            } catch {
                if !failed {
                    failed = true
                    Logger.voice.error("Hey Atlas: the model will not score: \(String(describing: error), privacy: .public)")
                }
                continue
            }
            if !scored {
                scored = true
                Logger.voice.notice("Hey Atlas: scoring ok")
                await onScoring()
            }
            if let top = peak.add(score) {
                Logger.voice.notice("Hey Atlas: peak \(top, format: .fixed(precision: 3), privacy: .public) over 2 s")
            }
            if score >= threshold {
                Logger.voice.notice("Hey Atlas: heard it, \(score, format: .fixed(precision: 3), privacy: .public)")
                hits.yield(score)
                return
            }
        }
    }
}

/// The last two seconds of 16 kHz audio, and when to score them.
///
/// EXACTLY 32 000 SAMPLES, because that is what `predict` wants: much under
/// (about 31 500) it cannot fill its sixteen embedding windows and returns 0,
/// and over 48 000 it keeps the OLDEST three seconds - the wrong end.
struct WakeWindow {
    static let size = 32_000
    /// 80 ms of new audio between scores.
    static let hop = 1_280
    static let scoresPerTwoSeconds = 2 * 16_000 / hop

    private var ring = [Int16](repeating: 0, count: size)
    /// Where the next sample goes, which is also where the oldest one is.
    private var next = 0
    private var filled = 0
    /// Samples in since the last window was handed out.
    private var fresh = 0

    /// Adds the mic's samples. Returns the window, oldest first, when a score
    /// is due: it is full, and a hop's worth is new since the last.
    mutating func append(_ samples: [Int16]) -> [Int16]? {
        for sample in samples.suffix(Self.size) {
            ring[next] = sample
            next += 1
            if next == Self.size { next = 0 }
        }
        filled = min(filled + samples.count, Self.size)
        fresh += samples.count
        guard filled == Self.size, fresh >= Self.hop else { return nil }
        fresh = 0
        return Array(ring[next...]) + ring[..<next]
    }
}

/// The highest score over every `every` scores - about two seconds' worth.
struct WakePeak {
    let every: Int
    private var count = 0
    private var top: Float = 0

    init(every: Int) { self.every = every }

    /// The peak once `every` scores are in, then starts over.
    mutating func add(_ score: Float) -> Float? {
        top = count == 0 ? score : max(top, score)
        count += 1
        guard count == every else { return nil }
        count = 0
        return top
    }
}

/// The mic's format → 16 kHz mono Int16. ONE PER ENGINE, and streaming: the
/// resampler carries its state from one buffer to the next, so each buffer
/// is handed over once and then `.noDataNow` - `.endOfStream` would end the
/// stream, and a converter made per buffer would click at every boundary.
///
/// `@unchecked Sendable` because the audio thread is the only one that uses
/// it, one buffer at a time, once the tap is installed.
final class WakeConverter: @unchecked Sendable {
    static let rate = 16_000.0

    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init?(from input: AVAudioFormat) {
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: Self.rate,
                channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: input, to: target)
        else { return nil }
        self.target = target
        self.converter = converter
    }

    /// Room for `frames` at `rate` once they are 16 kHz, plus a little for
    /// the resampler's own rounding.
    static func capacity(frames: Int, rate: Double) -> Int {
        Int((Double(frames) * Self.rate / rate).rounded(.up)) + 8
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16]? {
        let capacity = Self.capacity(frames: Int(buffer.frameLength), rate: buffer.format.sampleRate)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(capacity)) else { return nil }
        let handover = Handover(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in
            handover.next(status)
        }
        guard status != .error, error == nil, let data = out.int16ChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    /// Gives the converter its one buffer, then says there is no more for now.
    private final class Handover: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let buffer else {
                status.pointee = .noDataNow
                return nil
            }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }
}
