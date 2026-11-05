// Agents/Voice/KokoroVoice.swift
import AVFoundation
import os

/// Reads answers aloud in Kokoro's voice, synthesised on atlas and streamed
/// through the hub (`HubClient.speech`), played through `VoiceOutput` like
/// every other voice so echo cancellation can hear it.
///
/// ONE CHUNK AT A TIME, see `SpeechChunks` for their sizes. The next is asked
/// for as soon as the one before it has ALL ARRIVED, while it is still
/// playing, and never two at once: atlas synthesises with two CPUs, and two
/// requests would share them and both come later.
///
/// IT CAN FAIL PARTWAY, and says how far it got (`SpeechFailure.delivered`),
/// so `FallbackVoice` can read the rest in the Apple voice. What had arrived
/// by then plays on.
@MainActor
final class KokoroVoice: Speaking, ChunkedSpeaking {
    typealias Fetch = @MainActor (String) -> AsyncThrowingStream<Data, Error>

    /// How long nothing may play, with nothing arriving, before a reading
    /// is given up as stalled. Kokoro's slowest chunk is about 40 words,
    /// some 8 s of synthesis, and the sizes are chosen so the next chunk is
    /// always ready before the one before it ends: silence this long means
    /// it is not coming.
    static let stallAfter: TimeInterval = 2.5

    private let output: SpeechOutput
    private let fetch: Fetch
    private let clock: @MainActor () -> TimeInterval
    private let stallAfter: TimeInterval
    /// Waits, so the stall watchdog can be run on a test's own time.
    private let nap: @MainActor (TimeInterval) async -> Void
    /// Counts speaks, so an earlier one's late work (one `stop` already
    /// ended) is told apart from the one being read now.
    private var reading = 0
    /// Whoever is waiting for the reading to end. nil when nothing is being
    /// read.
    private var waiting: CheckedContinuation<SpeechFailure?, Never>?
    /// Fetches, decodes and schedules the chunks, in order.
    private var feeding: Task<Void, Never>?
    /// This voice has put audio on the shared output that may not have
    /// played yet: from the first buffer of a reading until it drains, or
    /// is stopped. After a failure midway it stays set, since that audio
    /// plays on under the Apple voice, and a stop must silence it too.
    private var holdsOutput = false
    private var chunks: [String] = []
    private var timeline = PlayoutTimeline()
    /// Chunks that have reached the output whole, this reading.
    private var delivered = 0
    /// Something arrived for the chunk in flight since the stall watchdog
    /// last looked: a slow trickle is still a live connection.
    private var receiving = false
    /// Watches for a reading gone quiet. See `watchForStall`.
    private var stalls: Task<Void, Never>?

    /// `fetch`, `clock` and `nap` are the seams for tests: a fake hub, and a
    /// time and a wait they control.
    init(
        output: SpeechOutput,
        fetch: @escaping Fetch = { HubClient.shared.speech($0) },
        clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        stallAfter: TimeInterval = KokoroVoice.stallAfter,
        nap: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.output = output
        self.fetch = fetch
        self.clock = clock
        self.stallAfter = stallAfter
        self.nap = nap
    }

    /// Reads `text` in Kokoro's voice, AND SAYS NOTHING AT ALL IF KOKORO
    /// CANNOT. Not the app's path: `VoiceSession` speaks through
    /// `FallbackVoice`, which is what turns a failure into the Apple voice
    /// reading the rest. This is for a caller that has no fallback to offer
    /// - a test, or a one-off - and it logs what went unsaid.
    func speak(_ text: String) async {
        let chunks = SpeechChunks.split(text)
        guard let failure = await speak(chunks, onFirstAudio: {}) else { return }
        Logger.voice.error(
            """
            Voice: \(chunks.count - failure.delivered, privacy: .public) of \
            \(chunks.count, privacy: .public) chunks went unsaid: Kokoro failed \
            (\(String(describing: failure.reason), privacy: .public)) with no voice to fall back on
            """)
    }

    func speak(_ chunks: [String], onFirstAudio: @escaping @MainActor () -> Void) async -> SpeechFailure? {
        // Never two readings: the first is cut off, as in AppleVoice.
        if waiting != nil { stop() }
        guard !chunks.isEmpty else { return nil }
        reading += 1
        let id = reading
        self.chunks = chunks
        timeline = PlayoutTimeline()
        holdsOutput = false
        delivered = 0
        receiving = false
        return await withCheckedContinuation { c in
            waiting = c
            feeding = Task { await self.play(chunks, id, onFirstAudio) }
        }
    }

    /// Silence, and `speak` returns NOW, with no failure: nothing is to be
    /// read after a stop. The request in flight is cancelled with the task
    /// reading it, so atlas stops synthesising for nobody.
    func stop() {
        feeding?.cancel()
        feeding = nil
        stalls?.cancel()
        stalls = nil
        // Only this voice's own audio: the output is shared.
        if waiting != nil || holdsOutput { output.stop() }
        clear()
        end(reading, nil)
    }

    /// What is playing: the chunk being heard, or last heard while the next
    /// is still on its way, and the one before it. For the echo guard.
    var speakingNow: [String] {
        let now = clock()
        guard let index = timeline.chunk(at: now), index < chunks.count,
            waiting != nil || now < timeline.end
        else { return [] }
        return Array(chunks[max(0, index - 1)...index])
    }

    private func play(_ chunks: [String], _ id: Int, _ onFirstAudio: @escaping @MainActor () -> Void) async {
        let converter = OutputConverter(to: output.format)
        let started = clock()
        for (index, chunk) in chunks.enumerated() {
            // ONE BATCHER PER CHUNK: its first batch is a tenth of a second,
            // so a chunk that arrives after the output has run dry starts
            // playing at once rather than gathering half a second first.
            let batcher = SpeechBatcher(format: output.format)
            let asked = clock()
            var arrived: TimeInterval?
            var pcm = PCM16LE()
            var frames = 0
            var failure: TTSError?
            receiving = false
            do {
                for try await piece in fetch(chunk) {
                    guard live(id) else { return }
                    if arrived == nil { arrived = clock() }
                    receiving = true
                    guard let buffer = buffer(pcm.decode(piece), converting: converter) else { continue }
                    frames += Int(buffer.frameLength)
                    for batch in batcher.append(buffer) { schedule(batch, of: index, onFirstAudio) }
                }
                // A 200 with no audio in it: the chunk would be lost unsaid.
                if frames == 0 { failure = .torn }
            } catch {
                failure = error as? TTSError ?? .torn
            }
            guard live(id) else { return }
            if let failure {
                // THE REST IS THE CALLER'S TO SAY, this chunk included, from
                // its start. What of it is still being batched is dropped;
                // what was scheduled plays on.
                _ = batcher.flush()
                Logger.voice.error(
                    """
                    Voice: Kokoro failed (\(String(describing: failure), privacy: .public)) on chunk \
                    \(index + 1, privacy: .public) of \(chunks.count, privacy: .public)
                    """)
                end(id, SpeechFailure(reason: failure, delivered: index))
                return
            }
            if let last = batcher.flush() { schedule(last, of: index, onFirstAudio) }
            delivered = index + 1
            // THE DEVICE CHECK READS THIS: how long each chunk took against
            // how long it plays. Counts and times only, never the words.
            let now = clock()
            Logger.voice.notice(
                """
                Voice: Kokoro chunk \(index + 1, privacy: .public) of \(chunks.count, privacy: .public), \
                \(chunk.split(separator: " ").count, privacy: .public) words, \
                \(Double(frames) / VoiceOutput.rate, format: .fixed(precision: 1), privacy: .public) s of speech: \
                first byte \((arrived ?? now) - asked, format: .fixed(precision: 2), privacy: .public) s, \
                all \(now - asked, format: .fixed(precision: 2), privacy: .public) s \
                (\(now - started, format: .fixed(precision: 2), privacy: .public) s into the answer)
                """)
        }
        await output.drained()
        guard live(id) else { return }
        clear()
        end(id, nil)
    }

    /// Plays `batch`, the next of chunk `index`, and tells the caller when
    /// it is the first audio of the reading. Audio that comes after the
    /// output has run dry is logged: that silence mid-answer is what the
    /// chunk sizes are meant to hide.
    private func schedule(_ batch: AVAudioPCMBuffer, of index: Int, _ onFirstAudio: @MainActor () -> Void) {
        let seconds = Double(batch.frameLength) / batch.format.sampleRate
        let gap = timeline.scheduled(chunk: index, seconds: seconds, at: clock())
        if gap > 0.05 {
            Logger.voice.notice("Voice: Kokoro ran dry for \(gap, format: .fixed(precision: 2), privacy: .public) s, at chunk \(index + 1, privacy: .public)")
        }
        output.schedule(batch)
        let first = !holdsOutput
        holdsOutput = true
        if first {
            onFirstAudio()
            // From here on, silence is this voice's own to notice: before
            // the first audio there is nothing to go dry, and that window
            // belongs to `FallbackVoice`.
            stalls = watchForStall(reading)
        }
    }

    /// Gives up on a reading that has gone quiet: nothing playing, and
    /// nothing arriving, for `stallAfter`.
    ///
    /// WITHOUT THIS, THE ONLY BACKSTOP IS THE REQUEST TIMEOUT - 12 s of
    /// silence with the mic open, and `FallbackVoice`'s window is long since
    /// closed, since that one only watches for the FIRST audio. A phone
    /// walking out of Wi-Fi at chunk 4 of 9, or Kokoro wedging mid-answer,
    /// both look exactly like this. Ending with `.stalled` hands the rest to
    /// the Apple voice, the same way any other failure midway does.
    private func watchForStall(_ id: Int) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.live(id), self.delivered < self.chunks.count else { return }
                let dry = self.clock() - self.timeline.end
                guard dry >= self.stallAfter else {
                    // Something is still playing, or was until just now.
                    await self.nap(self.stallAfter - dry)
                    continue
                }
                guard !self.receiving else {
                    // A slow trickle is still a live connection: one more
                    // window before giving up on it.
                    self.receiving = false
                    await self.nap(self.stallAfter)
                    continue
                }
                self.stalled(id)
                return
            }
        }
    }

    private func stalled(_ id: Int) {
        guard live(id) else { return }
        Logger.voice.error(
            """
            Voice: Kokoro went quiet with \(self.delivered, privacy: .public) of \
            \(self.chunks.count, privacy: .public) chunks read, and nothing playing
            """)
        feeding?.cancel()
        feeding = nil
        end(id, SpeechFailure(reason: .stalled, delivered: delivered))
    }

    /// `samples`, at Kokoro's 24 kHz mono, as a buffer in the output's
    /// format: as they are, since `VoiceOutput` plays at Kokoro's own rate,
    /// and through `converter` should that ever change.
    private func buffer(_ samples: [Float], converting converter: OutputConverter) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(pcmFormat: Self.kokoro, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer.format == output.format ? buffer : converter.convert(buffer)
    }

    private static let kokoro: AVAudioFormat = {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: VoiceOutput.rate, channels: 1) else {
            fatalError("24 kHz mono float is always a valid format")
        }
        return format
    }()

    /// Reading number `id` is still the one being read.
    private func live(_ id: Int) -> Bool {
        id == reading && waiting != nil
    }

    /// Nothing of a reading is playing: it drained, or was stopped.
    private func clear() {
        holdsOutput = false
        chunks = []
        timeline = PlayoutTimeline()
    }

    /// Ends speak number `id` with `result`, if it is the one being read.
    private func end(_ id: Int, _ result: SpeechFailure?) {
        guard id == reading, let waiting else { return }
        self.waiting = nil
        feeding = nil
        stalls?.cancel()
        stalls = nil
        waiting.resume(returning: result)
    }
}

/// Where a speaker's buffers go: `VoiceOutput`, or a test's fake.
@MainActor protocol SpeechOutput: AnyObject {
    var format: AVAudioFormat { get }
    func schedule(_ buffer: AVAudioPCMBuffer)
    func stop()
    func drained() async
}

extension VoiceOutput: SpeechOutput {}

/// Kokoro's samples, little-endian 16-bit, as floats, a piece at a time.
///
/// LITTLE-ENDIAN, whatever `audio/L16` says: its RFC means big-endian, and
/// the hub passes Kokoro's own bytes through. A PIECE CAN END HALFWAY
/// THROUGH A SAMPLE, wherever the network cut it, so the odd byte waits for
/// its other half; dropped, it would shift every sample after it by a byte,
/// which is loud noise.
struct PCM16LE {
    private var carry: UInt8?

    mutating func decode(_ data: Data) -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity((data.count + 1) / 2)
        var bytes = data.makeIterator()
        if let low = carry {
            guard let high = bytes.next() else { return [] }
            samples.append(Self.sample(low, high))
            carry = nil
        }
        while let low = bytes.next() {
            guard let high = bytes.next() else {
                carry = low
                break
            }
            samples.append(Self.sample(low, high))
        }
        return samples
    }

    private static func sample(_ low: UInt8, _ high: UInt8) -> Float {
        Float(Int16(bitPattern: UInt16(low) | UInt16(high) << 8)) / 32_768
    }
}

/// When each chunk's audio plays, worked out from when it was scheduled:
/// after everything already queued, or at once if the output has run dry.
/// What `KokoroVoice.speakingNow` reads. An estimate: the hardware's own
/// latency, a few hundredths of a second, is not in it.
struct PlayoutTimeline {
    /// When each chunk starts to be heard.
    private(set) var starts: [TimeInterval] = []
    /// When the last of what is scheduled will have been heard.
    private(set) var end: TimeInterval = 0

    /// `seconds` more of chunk `chunk`, scheduled at `now`. Returns the
    /// silence before it: how long the output had been dry.
    @discardableResult
    mutating func scheduled(chunk: Int, seconds: TimeInterval, at now: TimeInterval) -> TimeInterval {
        let start = max(end, now)
        let gap = starts.isEmpty ? 0 : max(0, now - end)
        while starts.count <= chunk { starts.append(start) }
        end = start + seconds
        return gap
    }

    /// The chunk being heard at `now`, or the last one heard if nothing is
    /// playing. nil before any.
    func chunk(at now: TimeInterval) -> Int? {
        starts.lastIndex { $0 <= now }
    }
}
