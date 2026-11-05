// Agents/Voice/AppleVoice.swift
import AVFoundation
import os

/// Reads answers aloud with the best English voice on the phone, THROUGH
/// `VoiceOutput`.
///
/// The synthesiser WRITES the speech and this plays it, rather than letting
/// the synthesiser play it on an output of its own. Echo cancellation cannot
/// see that output, so the mic would hear Atlas as someone talking over it.
///
/// A Premium or Enhanced voice sounds far better than the default compact one.
/// They're a free download in Settings > Accessibility > Spoken Content >
/// Voices. This picks the best one installed, so downloading one needs no
/// code change.
///
/// THE END OF A READING CAN COME FROM THREE PLACES, because nothing promises
/// the first two: the empty buffer the synthesiser writes last, its
/// delegate's didFinish or didCancel, and a watchdog for a synthesiser that
/// goes quiet without either. They all go through one `SpeechWriter`, which
/// ends the reading once and says the last of what it had batched.
@MainActor
final class AppleVoice: NSObject, Speaking, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let output: VoiceOutput
    /// Counts speaks, so a late end of an earlier one (one `stop` already
    /// ended) is told apart from the one being read now.
    private var reading = 0
    /// Whoever is waiting for the reading to end. nil when nothing is being
    /// read.
    private var waiting: CheckedContinuation<Void, Never>?
    /// Carries what the synthesiser writes to `output`, in order.
    private var feeding: Task<Void, Never>?
    /// Ends a reading whose synthesiser has gone quiet - see `WriteWatchdog`.
    private var watchdog: Task<Void, Never>?
    private var writer: SpeechWriter?
    /// The utterance being read, kept alive for as long as it is being read
    /// so that nothing else can ever be the same object - see `writing`.
    private var current: AVSpeechUtterance?
    /// What the delegate, off the main actor, is allowed to end.
    nonisolated private let writing = CurrentWriting()
    /// The whole of what is being read: the synthesiser writes it as one.
    private(set) var speakingNow: [String] = []

    init(output: VoiceOutput) {
        self.output = output
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) async {
        // The session never overlaps two speaks, but if it ever did, the
        // first is cut off and returns here. Otherwise the second would take
        // over `waiting`, and the first would never return at all.
        if waiting != nil { stop() }
        // Nothing to say. Whether the synthesiser ever reports the end of
        // an empty utterance is not written down anywhere.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        reading += 1
        let id = reading
        speakingNow = [text]
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        let (written, sink) = AsyncStream.makeStream(of: WrittenSpeech.self)
        let writer = SpeechWriter(to: output.format, into: sink)
        await withCheckedContinuation { c in
            waiting = c
            current = utterance
            self.writer = writer
            writing.set(utterance, writer)
            feeding = Task { await self.play(written, id) }
            watch(writer, id)
            synth.write(utterance, toBufferCallback: Self.callback(writer))
        }
    }

    /// Cuts the reading off and returns from `speak` NOW, not when the last
    /// of it would have played. If that never came, a stuck speak would hold
    /// the session in `.speaking` with the mic open, and Cancel (which lands
    /// here) could not get it out.
    func stop() {
        synth.stopSpeaking(at: .immediate)
        // Only this voice's own reading: the output is shared.
        if waiting != nil { output.stop() }
        done(reading)
    }

    /// Schedules the speech as it is written, and once it is all written,
    /// waits for the last of it to be heard.
    private func play(_ written: AsyncStream<WrittenSpeech>, _ id: Int) async {
        for await piece in written {
            guard id == reading, waiting != nil else { return }
            switch piece {
            case .audio(let chunk):
                output.schedule(chunk.buffer)
            case .end:
                await output.drained()
                done(id)
                return
            }
        }
    }

    /// Ends reading number `id`, if it is the one being read. Any other, one
    /// `stop` already ended, is ignored.
    private func done(_ id: Int) {
        guard id == reading, let waiting else { return }
        self.waiting = nil
        speakingNow = []
        writing.clear()
        current = nil
        // A stopped synthesiser can go on writing for a while (218 more
        // buffers after a stop, in the Simulator). Ending the writer is what
        // stops that being converted and batched for nobody.
        writer?.end()
        writer = nil
        watchdog?.cancel()
        watchdog = nil
        feeding?.cancel()
        feeding = nil
        waiting.resume()
    }

    /// Ends a reading whose synthesiser stopped writing without ever saying
    /// it had finished - see `WriteWatchdog` for why that is the end of it.
    /// Checked every half second, which is as often as it can be worth.
    private func watch(_ writer: SpeechWriter, _ id: Int) {
        watchdog?.cancel()
        let started = ProcessInfo.processInfo.systemUptime
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.reading == id, self.waiting != nil else { return }
                guard
                    WriteWatchdog.gaveUp(
                        now: ProcessInfo.processInfo.systemUptime, started: started,
                        lastWrite: writer.lastWrite, ended: writer.hasEnded,
                        drained: self.output.isDrained)
                else { continue }
                Logger.voice.error(
                    """
                    Voice: the synthesiser stopped writing without finishing \
                    \(writer.lastWrite == nil ? "and wrote nothing at all" : "", privacy: .public)
                    """)
                self.synth.stopSpeaking(at: .immediate)
                // Through the writer, so a reading never ends twice.
                writer.end()
                return
            }
        }
    }

    /// The synthesiser has finished with `utterance`, or cancelled it. NOT
    /// THE READING'S USUAL END - the empty buffer is, and it has come by now
    /// - but it is what catches a write that quietly delivered nothing.
    ///
    /// NONISOLATED, and it looks the writer up while the utterance it names
    /// is alive: two live utterances are never the same object, and once a
    /// reading is over, its writer has ended and does nothing anyway.
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        writing.end(utterance)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        writing.end(utterance)
    }

    /// The synthesiser's buffer callback. NONISOLATED ON PURPOSE: it is
    /// called on the synthesiser's own queue, and a closure written inside
    /// this @MainActor class would be inferred main-actor-isolated, which
    /// Swift 6 checks at run time and traps on. (In the Simulator it came on
    /// the main thread; nothing says it always will.) The writer converts
    /// and batches there, so the main actor only schedules, and nothing of
    /// the synthesiser's own buffer is read after the callback returns.
    nonisolated private static func callback(_ writer: SpeechWriter) -> AVSpeechSynthesizer.BufferCallback {
        { buffer in writer.write(buffer) }
    }

    /// The best-quality en-US voice installed, novelty voices (Bells, Bubbles
    /// and the rest) left out. Only an Enhanced or Premium one is worth
    /// choosing; with none installed, the system's own en-US default.
    private static let voice: AVSpeechSynthesisVoice? =
        AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language == "en-US" && !$0.voiceTraits.contains(.isNoveltyVoice) }
        .filter { $0.quality.rawValue > AVSpeechSynthesisVoiceQuality.default.rawValue }
        .max { $0.quality.rawValue < $1.quality.rawValue }
        ?? AVSpeechSynthesisVoice(language: "en-US")
}

/// The reading the synthesiser's delegate may end: which utterance it is,
/// and the writer that ends it.
///
/// LOOKED UP ON THE DELEGATE'S OWN THREAD, while the utterance it was handed
/// is still alive, rather than after a hop to the main actor. Two live
/// objects are never the same object, so an utterance from an earlier
/// reading can never be taken for this one - which it could be after a hop,
/// once it has been freed and a new one has taken its address.
final class CurrentWriting: @unchecked Sendable {
    private let lock = NSLock()
    private var reading: (utterance: ObjectIdentifier, writer: SpeechWriter)?

    func set(_ utterance: AVSpeechUtterance, _ writer: SpeechWriter) {
        lock.withLock { reading = (ObjectIdentifier(utterance), writer) }
    }

    func clear() {
        lock.withLock { reading = nil }
    }

    /// Ends the reading `utterance` belongs to, if it is the one being read.
    func end(_ utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let writer: SpeechWriter? = lock.withLock { reading?.utterance == id ? reading?.writer : nil }
        writer?.end()
    }
}

/// One reading's speech, from the synthesiser to the main actor: converted,
/// batched, and in order. And ENDED ONCE, whichever of the three ends gets
/// there first, with whatever was still in the batcher said rather than cut.
///
/// `@unchecked Sendable`, and locked rather than isolated, because its ends
/// come from different threads: the synthesiser's queue writes, while the
/// delegate and the watchdog end it from the main actor.
final class SpeechWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: OutputConverter
    private let batcher: SpeechBatcher
    private let sink: AsyncStream<WrittenSpeech>.Continuation
    private let now: @Sendable () -> TimeInterval
    private var ended = false
    private var wrote: TimeInterval?

    /// `now` is the seam for tests; by default, the clock the watchdog reads.
    init(
        to format: AVAudioFormat, into sink: AsyncStream<WrittenSpeech>.Continuation,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        converter = OutputConverter(to: format)
        batcher = SpeechBatcher(format: format)
        self.sink = sink
        self.now = now
    }

    /// When the synthesiser last wrote anything, nil if it never has.
    var lastWrite: TimeInterval? { lock.withLock { wrote } }
    var hasEnded: Bool { lock.withLock { ended } }

    /// The synthesiser's callback: speech, or the empty buffer it writes
    /// last to say that was all.
    func write(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        var ending = false
        let batches: [AVAudioPCMBuffer] = lock.withLock {
            guard !ended else { return [] }
            wrote = now()
            guard pcm.frameLength > 0 else {
                ending = true
                return finish()
            }
            guard let converted = converter.convert(pcm) else { return [] }
            return batcher.append(converted)
        }
        deliver(batches, ending: ending)
    }

    /// Ends the reading from somewhere other than the synthesiser's last
    /// buffer: its delegate, the watchdog, or a stop. Does nothing if it has
    /// already ended.
    func end() {
        var ending = false
        let last: [AVAudioPCMBuffer] = lock.withLock {
            guard !ended else { return [] }
            ending = true
            return finish()
        }
        deliver(last, ending: ending)
    }

    /// Ends it, under the lock: the last of what was batched comes back to
    /// be said, and nothing more is ever taken from the synthesiser.
    private func finish() -> [AVAudioPCMBuffer] {
        ended = true
        return [batcher.flush()].compactMap { $0 }
    }

    /// THE LAST OF THE SPEECH BEFORE THE END, never after it: the reading
    /// stops at `.end`, and audio behind it would never be said.
    private func deliver(_ batches: [AVAudioPCMBuffer], ending: Bool) {
        for batch in batches { sink.yield(.audio(SpeechChunk(buffer: batch))) }
        guard ending else { return }
        sink.yield(.end)
        sink.finish()
    }
}

/// When a reading has to be ended although the synthesiser never said it had
/// finished - it delivered no last empty buffer, and no didFinish. A write
/// straight after a `stopSpeaking` can be dropped in silence, and the header
/// promises nothing either way.
///
/// THE SYNTHESISER WRITES FAR FASTER THAN THE SPEECH PLAYS: in the Simulator
/// a whole answer arrived in a few tens of milliseconds, after about a third
/// of a second's wait for the first buffer. So a long silence with nothing
/// left to play means nothing more is coming. Never while there is still
/// speech to play, which covers a long answer and Kokoro's audio still ahead
/// of the Apple voice on the same output.
enum WriteWatchdog {
    /// A voice being loaded for the first time can take a moment.
    static let firstWrite: TimeInterval = 5
    static let quiet: TimeInterval = 2

    static func gaveUp(
        now: TimeInterval, started: TimeInterval, lastWrite: TimeInterval?,
        ended: Bool, drained: Bool
    ) -> Bool {
        guard !ended, drained else { return false }
        guard let lastWrite else { return now - started >= firstWrite }
        return now - lastWrite >= quiet
    }
}

/// What the synthesiser's queue hands the main actor: speech, then the end.
enum WrittenSpeech: Sendable {
    case audio(SpeechChunk)
    case end
}

/// A batched buffer on its way to the main actor. `@unchecked Sendable`
/// because it is a fresh buffer made for this one handover, and nothing
/// touches it on the way.
struct SpeechChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
