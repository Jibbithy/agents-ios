// Agents/Voice/VoiceOutput.swift
import AVFoundation
import os

/// Where every spoken word plays: one player on the voice session's engine.
///
/// ON THE SAME ENGINE AS THE MIC, deliberately. Echo cancellation (voice
/// processing, see `AudioSessionVoice`) takes out of the mic only what that
/// same engine played. A voice played any other way, such as the
/// synthesiser's own output, reaches the mic as if someone were talking, and
/// Atlas could never be talked over without interrupting itself.
///
/// ONE FIXED FORMAT, whatever the route: 24 kHz mono float, Kokoro's own
/// rate. The main mixer converts it to whatever the hardware runs at. So a
/// buffer converted for one engine plays unchanged on the next one a route
/// change brings, and a speaker never needs to know which engine it is on.
///
/// AND ONE I/O UNIT AT A TIME: see `route`. An engine of its own is for the
/// one case the mic cannot cover - it never opened, or it died and could not
/// be brought back - and that is where "Mic busy." is said. It plays nothing
/// at all outside a session, between `close` and the next `open`.
@MainActor
final class VoiceOutput {
    nonisolated static let rate = 24_000.0

    /// What every scheduled buffer must be in. See `OutputConverter`.
    let format: AVAudioFormat

    /// A session is under way: speech may play. See `open` and `close`.
    private var isOpen = false
    private var player: AVAudioPlayerNode?
    /// The engine `player` is on: the session's, or one of this one's own.
    private var host: AVAudioEngine?
    private var ownsHost = false
    /// An engine of its own would not start, or had nothing to play into.
    /// Not tried again for every buffer of the same reading: only once the
    /// session attaches an engine, or lets one go.
    private var ownFailed = false
    private var ledger = PlayoutLedger<CheckedContinuation<Void, Never>>()
    /// The cues' own player - chimes and the thinking hum - BESIDE the
    /// voice's on the same engine, never on it: a looping hum on the voice's
    /// player would sit ahead of every word in its queue, and the ledger would
    /// count it. Same engine, so echo cancellation takes it out of the mic
    /// like the voice. Only on the mic's engine; an engine of this one's own
    /// (the "Mic busy." case) has no cues.
    private var cuePlayer: AVAudioPlayerNode?
    /// The session wants the hum on - see `thinking`. Kept across an engine
    /// restart, which drops the player: `engineStarted` puts it back.
    private var humWanted = false
    /// The hum is scheduled on `cuePlayer` right now.
    private var humming = false
    private lazy var humBuffer: AVAudioPCMBuffer? = buffer(CueSynth.thinkingLoop())
    private lazy var chimes: [Cue: AVAudioPCMBuffer] = {
        var out: [Cue: AVAudioPCMBuffer] = [:]
        for cue in [Cue.listening, .ending] { out[cue] = buffer(CueSynth.samples(for: cue)) }
        return out
    }()

    init() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1) else {
            fatalError("24 kHz mono float is always a valid format")
        }
        self.format = format
    }

    /// Nothing is left to play: everything scheduled has been heard, or
    /// dropped. What `AppleVoice`'s watchdog reads.
    var isDrained: Bool { ledger.isDrained }

    /// A voice session has begun. Speech plays from here until `close`, on
    /// the mic's engine once `attach` brings one, and on an engine of its
    /// own until then - which is how a mic that never opened still says so.
    func open() {
        isOpen = true
        ownFailed = false
    }

    /// The session is over: everything scheduled is dropped, an engine of
    /// its own is stopped, and anything scheduled after this is dropped too,
    /// until the next `open`. WITHOUT THAT LAST PART, a chunk landing late -
    /// the hub answering after the session ended - would start an engine of
    /// its own and switch the ducking audio session back on, with nobody
    /// left to switch it off again.
    func close() {
        humWanted = false
        release()
        isOpen = false
    }

    /// Puts a fresh player on the session's fresh engine, before it starts.
    /// AFTER VOICE PROCESSING IS SETTLED on it: that changes the output side
    /// too, and the main mixer is connected to the output in whatever format
    /// the output has when the mixer is first asked for. `feeding` is the
    /// format the mixer must feed the output in - the input's, with voice
    /// processing on, whose two ends must match (AVAudioIONode.h) - or nil
    /// to leave that to the engine.
    ///
    /// Whatever the last engine had scheduled is dropped, and `drained`
    /// returns.
    func attach(to engine: AVAudioEngine, feeding: AVAudioFormat? = nil) {
        release()
        ownFailed = false
        host = engine
        // NOTHING TOUCHES THE MAIN MIXER until the output is known to be
        // there: connecting to an output with no rate or no channels raises
        // an exception Swift cannot catch. The engine still runs, for the
        // mic; this session simply says nothing.
        guard Self.canPlay(engine.outputNode.outputFormat(forBus: 0)) else {
            Logger.voice.error("Voice: the engine has no output to speak through, so it will not speak")
            return
        }
        if let feeding { engine.connect(engine.mainMixerNode, to: engine.outputNode, format: feeding) }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        self.player = player
        // A MIXER TAKES THE NEXT FREE INPUT BUS on a plain `connect`
        // (AVAudioEngine.h), so the cues mix in beside the voice.
        let cues = AVAudioPlayerNode()
        engine.attach(cues)
        engine.connect(cues, to: engine.mainMixerNode, format: format)
        cuePlayer = cues
    }

    /// The session's engine has started with this output attached: a hum
    /// that a restart dropped mid-thought comes back.
    func engineStarted() {
        if humWanted { startHum() }
    }

    // MARK: - cues

    /// The thinking hum, on or off. Off also happens by itself at the first
    /// buffer of speech - see `schedule`.
    func thinking(_ on: Bool) {
        humWanted = on
        if on { startHum() } else { stopHum() }
    }

    /// Plays a chime, and returns once it has been HEARD - or at once, with
    /// nothing to play it on. A BACKSTOP returns it anyway a little after its
    /// length: a player whose engine is thrown away mid-chime never calls
    /// back, and the listen waiting on this must not wait forever.
    func play(_ cue: Cue) async {
        guard isOpen, let player = cuePlayer, let host, host.isRunning,
            let buffer = chimes[cue]
        else { return }
        // Behind a LOOPING hum a chime would never play at all.
        stopHum()
        let seconds = Double(buffer.frameLength) / Self.rate
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(c)
            player.scheduleBuffer(
                buffer, completionCallbackType: .dataPlayedBack,
                completionHandler: Self.cueDone(once))
            guard startCues(player, on: host) else {
                once.resume()
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds + 0.4))
                once.resume()
            }
        }
    }

    private func startHum() {
        guard !humming, isOpen, let player = cuePlayer, let host, host.isRunning,
            let humBuffer
        else { return }
        player.scheduleBuffer(humBuffer, at: nil, options: .loops)
        humming = startCues(player, on: host)
        // NOT LEFT SCHEDULED on a player that would not start: the next
        // chime would start it, and play the endless hum ahead of itself.
        if !humming, host.isRunning { player.stop() }
    }

    private func stopHum() {
        guard humming else { return }
        humming = false
        if host?.isRunning == true { cuePlayer?.stop() }
    }

    /// `start` for the cues' player, which must not `drop` the VOICE's
    /// queue when it fails. False if it did not start.
    private func startCues(_ player: AVAudioPlayerNode, on host: AVAudioEngine) -> Bool {
        guard host.isRunning else { return false }
        if player.isPlaying { return true }
        if #available(iOS 27.0, *) {
            do { try player.playAudio() } catch {
                Logger.voice.error("Voice: a cue would not play: \(error.domainAndCode, privacy: .public)")
                return false
            }
        } else {
            player.play()
        }
        return true
    }

    private func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let to = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { to.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// A chime's completion. NONISOLATED ON PURPOSE, for the reason on
    /// `played`.
    nonisolated private static func cueDone(_ once: ResumeOnce)
        -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    {
        { _ in once.resume() }
    }

    /// The session's engine is being thrown away: at a restart, or after one
    /// that failed. Everything scheduled on it is dropped and `drained`
    /// returns, rather than waiting on an engine that will never play again.
    /// The session is still open, so a failure can still be spoken - on an
    /// engine of this one's own, until a new one is attached.
    func detach() {
        release()
        ownFailed = false
    }

    /// Plays `buffer` after everything already scheduled. It must be in
    /// `format`. Dropped, and logged, if there is nothing to play it on.
    ///
    /// BIG BUFFERS, NOT MANY: batch them first (see `SpeechBatcher`). Every
    /// buffer still queued makes `stop`, and so a barge-in, block the main
    /// actor for longer.
    func schedule(_ buffer: AVAudioPCMBuffer) {
        // A player handed a buffer with another channel count raises an
        // exception Swift cannot catch, and one at another rate plays it at
        // the wrong speed.
        guard buffer.format == format else {
            Logger.voice.error(
                """
                Voice: a buffer in the wrong format was dropped (\(buffer.format.channelCount, privacy: .public) \
                channels at \(buffer.format.sampleRate, privacy: .public) Hz)
                """)
            return
        }
        guard buffer.frameLength > 0 else { return }
        switch Self.route(open: isOpen, host: hostState) {
        case .drop:
            // Nothing will play what is already scheduled either.
            drop()
            return
        case .ownEngine:
            guard startOwnEngine() else {
                drop()
                return
            }
        case .play:
            break
        }
        guard let player, let host, host.isRunning else {
            drop()
            return
        }
        let epoch = ledger.scheduled()
        player.scheduleBuffer(
            buffer, completionCallbackType: .dataPlayedBack,
            completionHandler: Self.played(epoch, on: self))
        if !player.isPlaying { start(player, on: host) }
        // THE HUM STOPS THE INSTANT SPEECH STARTS: the first buffer of any
        // voice, Kokoro or Apple, answer or the app's own words.
        if humWanted || humming {
            humWanted = false
            stopHum()
        }
    }

    /// Silence now. Everything scheduled is dropped, and `drained` returns.
    /// The engine goes on running: it is the mic's too.
    func stop() {
        // THE EPOCH MOVES ON FIRST. A stopped player calls back for every
        // buffer it dropped, and those must not count against whatever is
        // scheduled next.
        let waiters = ledger.dropAll()
        if let player, host?.isRunning == true { player.stop() }
        for waiter in waiters { waiter.resume() }
    }

    /// Returns once everything scheduled has been heard, or at once if
    /// nothing is left: after `stop`, after an engine restart dropped it,
    /// and on an engine that has stopped, whose buffers will never play.
    func drained() async {
        if case .stopped = hostState { drop() }
        await withCheckedContinuation { c in
            if let now = ledger.wait(c) { now.resume() }
        }
    }

    /// Where the next buffer goes. PURE, because this is the rule that keeps
    /// the voice to ONE I/O unit: a second engine alongside a mic that is
    /// merely stopped - mid route change, mid call - would be an output
    /// without echo cancellation, and every chunk Kokoro streams would land
    /// on it.
    nonisolated static func route(open: Bool, host: Host) -> Route {
        guard open else { return .drop }
        switch host {
        case .running: return .play
        case .gone: return .ownEngine
        case .stopped, .silent: return .drop
        }
    }

    /// An output that reports no rate or no channels has not come up: the
    /// audio server timed out, or there is no route. Connecting the main
    /// mixer to it raises an exception Swift cannot catch.
    nonisolated static func canPlay(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    /// The engine the player is on, as `route` sees it.
    enum Host: Equatable {
        /// None: the mic never opened, or its engine was thrown away.
        case gone
        case running
        /// Attached, but stopped: a route change, or an interruption.
        case stopped
        /// Attached, with nothing to play through - see `attach`.
        case silent
    }

    enum Route: Equatable { case play, ownEngine, drop }

    private var hostState: Host {
        guard let host else { return .gone }
        guard player != nil else { return .silent }
        return host.isRunning ? .running : .stopped
    }

    /// An engine of this one's own, output only, for when there is no mic to
    /// speak through: what says "Mic busy." A player told to play on an
    /// engine that is not running raises an exception Swift cannot catch, so
    /// this one is started before it is used.
    private func startOwnEngine() -> Bool {
        guard !ownFailed else { return false }
        release()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        // OUTPUT ONLY: its input node is never touched, so it needs no mic,
        // and no mic permission. The session is switched on first, BEFORE
        // the graph is built (building it brings the hardware output up),
        // because `AudioSessionVoice` may have switched it off when the mic
        // failed; its category is still the voice session's.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            guard Self.canPlay(engine.outputNode.outputFormat(forBus: 0)) else {
                Logger.voice.error("Voice: there is no audio output to speak through")
                ownFailed = true
                return false
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
        } catch {
            Logger.voice.error("Voice: nothing to play speech on: \(error.domainAndCode, privacy: .public)")
            ownFailed = true
            return false
        }
        Logger.voice.notice("Voice: speaking on an engine of its own, with no mic running")
        self.player = player
        host = engine
        ownsHost = true
        return true
    }

    /// Starts the player. CHECKED ONCE MORE right before: an engine stopped
    /// by a route change between the check and the call would raise an
    /// exception Swift cannot catch. From iOS 27 the throwing call closes
    /// that window for good.
    private func start(_ player: AVAudioPlayerNode, on host: AVAudioEngine) {
        guard host.isRunning else {
            drop()
            return
        }
        if #available(iOS 27.0, *) {
            do { try player.playAudio() } catch {
                Logger.voice.error("Voice: the voice would not start playing: \(error.domainAndCode, privacy: .public)")
                drop()
            }
        } else {
            player.play()
        }
    }

    /// Lets go of the player and whatever it had scheduled. Its engine is the
    /// session's to stop, unless it is this one's own.
    private func release() {
        if ownsHost { host?.stop() }
        // The cues go with the engine; `humWanted` stays, for `engineStarted`.
        cuePlayer = nil
        humming = false
        player = nil
        host = nil
        ownsHost = false
        drop()
    }

    /// Everything scheduled is gone, and whoever was waiting for it is woken.
    private func drop() {
        for waiter in ledger.dropAll() { waiter.resume() }
    }

    private func played(_ epoch: Int) {
        for waiter in ledger.played(epoch) { waiter.resume() }
    }

    /// A buffer's completion. NONISOLATED ON PURPOSE: the player calls it on
    /// a thread of its own, and a closure written inside this @MainActor class
    /// would be inferred main-actor-isolated, which Swift 6 checks at run
    /// time and traps on. It must not touch the player either: a player
    /// stopped from inside its own completion can deadlock (AVAudioPlayerNode.h).
    nonisolated private static func played(_ epoch: Int, on output: VoiceOutput)
        -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    {
        { [weak output] _ in
            Task { @MainActor in output?.played(epoch) }
        }
    }
}

/// Counts the buffers still to be heard, and holds whoever is waiting for
/// the last of them, so `VoiceOutput.drained` knows when to wake them.
///
/// EPOCHS, because a player that is stopped still calls back for every
/// buffer it dropped, and an engine that is thrown away never calls back at
/// all. Either way the count starts over, and a callback from before that
/// must not count against what is scheduled after.
struct PlayoutLedger<Waiter> {
    private(set) var epoch = 0
    private(set) var outstanding = 0
    private var waiters: [Waiter] = []

    var isDrained: Bool { outstanding == 0 }
    var waiting: Int { waiters.count }

    /// One more to play. Returns the epoch its callback reports back with.
    mutating func scheduled() -> Int {
        outstanding += 1
        return epoch
    }

    /// Waits for the last buffer to be heard. Returns `waiter` straight back
    /// when there is nothing to wait for.
    mutating func wait(_ waiter: Waiter) -> Waiter? {
        guard !isDrained else { return waiter }
        waiters.append(waiter)
        return nil
    }

    /// A buffer of `epoch` has been heard. Returns whoever that frees: every
    /// waiter, if it was the last buffer.
    mutating func played(_ epoch: Int) -> [Waiter] {
        guard epoch == self.epoch, outstanding > 0 else { return [] }
        outstanding -= 1
        return isDrained ? take() : []
    }

    /// Everything scheduled is gone: stopped, or its engine thrown away.
    /// Returns whoever was waiting for it, who would otherwise wait forever.
    mutating func dropAll() -> [Waiter] {
        epoch &+= 1
        outstanding = 0
        return take()
    }

    private mutating func take() -> [Waiter] {
        defer { waiters = [] }
        return waiters
    }
}

/// Gathers a speaker's small buffers into fewer, bigger ones for
/// `VoiceOutput`: the first a tenth of a second, so speech starts at once,
/// then half a second each.
///
/// BECAUSE A STOP COSTS PER BUFFER. `AVAudioPlayerNode.stop` blocks its
/// caller for every buffer still queued for `.dataPlayedBack`, and worse than
/// linearly: in the Simulator, 10 queued took 3 ms, 150 took 74 ms, and one
/// sentence as the synthesiser writes it (about 400 buffers of 256 frames)
/// took 0.9 s. A whole answer, about 45 s, is at most some 90 of these.
///
/// `@unchecked Sendable` for the reason on `OutputConverter`: one thread
/// uses it, one buffer at a time.
final class SpeechBatcher: @unchecked Sendable {
    static let firstFrames: AVAudioFrameCount = 2_400
    static let frames: AVAudioFrameCount = 12_000

    private let format: AVAudioFormat
    private var chunk: AVAudioPCMBuffer?
    private var made = 0

    /// `format` is `VoiceOutput.format`: mono float, one channel to copy.
    init(format: AVAudioFormat) {
        self.format = format
    }

    /// How big chunk number `index` is.
    static func size(of index: Int) -> AVAudioFrameCount {
        index == 0 ? firstFrames : frames
    }

    /// Adds `buffer`, which must be in `format`. Returns the chunks it
    /// filled, in order: often none.
    func append(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        guard buffer.format == format, let from = buffer.floatChannelData?[0] else { return [] }
        var full: [AVAudioPCMBuffer] = []
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            if chunk == nil {
                chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.size(of: made))
            }
            guard let chunk, let to = chunk.floatChannelData?[0] else { return full }
            let count = min(chunk.frameCapacity - chunk.frameLength, buffer.frameLength - offset)
            (to + Int(chunk.frameLength)).update(from: from + Int(offset), count: Int(count))
            chunk.frameLength += count
            offset += count
            if chunk.frameLength == chunk.frameCapacity {
                full.append(chunk)
                self.chunk = nil
                made += 1
            }
        }
        return full
    }

    /// Whatever is left over, at the end of the speech. nil if nothing is.
    func flush() -> AVAudioPCMBuffer? {
        defer { chunk = nil }
        guard let chunk, chunk.frameLength > 0 else { return nil }
        made += 1
        return chunk
    }
}

/// Any PCM, as a speaker produces it, into `VoiceOutput.format`.
///
/// ONE PER UTTERANCE, AND STREAMING, for the reason on `WakeConverter`: the
/// resampler carries its state from one buffer to the next, so each buffer
/// is handed over once and then `.noDataNow`. One made per buffer would click
/// at every boundary. Built from the first buffer's own format, because only
/// the synthesiser knows what a voice writes (it differs from voice to
/// voice; see `AVSpeechSynthesisVoice.audioFileSettings`).
///
/// `@unchecked Sendable` because only one thread uses it, one buffer at a
/// time: the one the speaker's audio arrives on.
final class OutputConverter: @unchecked Sendable {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var failed = false

    init(to target: AVAudioFormat) {
        self.target = target
    }

    /// Room for `frames` at `rate` once they are at `target`, plus a little
    /// for the resampler's own rounding. Too little, and the converter keeps
    /// the rest back until the next buffer.
    static func capacity(frames: AVAudioFrameCount, from rate: Double, to target: Double) -> AVAudioFrameCount {
        AVAudioFrameCount((Double(frames) * target / rate).rounded(.up)) + 8
    }

    /// `buffer` in the target format, nil if it cannot be converted. It can
    /// come back empty while the resampler fills.
    ///
    /// ALWAYS A FRESH BUFFER, a copy even when the format already matches:
    /// a speaker's buffer can be its own to reuse once its callback returns,
    /// and this one is played later, on another thread.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        let capacity = Self.capacity(
            frames: buffer.frameLength, from: buffer.format.sampleRate,
            to: target.sampleRate)
        guard let converter,
            let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else {
            return fail(buffer)
        }
        let handover = Handover(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in
            handover.next(status)
        }
        guard status != .error, error == nil else { return fail(buffer) }
        return out
    }

    /// Nil, and said once per utterance rather than once per buffer.
    private func fail(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if !failed {
            failed = true
            let format = buffer.format
            Logger.voice.error(
                """
                Voice: speech would not convert from \(format.channelCount, privacy: .public) channels \
                at \(format.sampleRate, privacy: .public) Hz (format \(format.commonFormat.rawValue, privacy: .public))
                """)
        }
        return nil
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

/// Resumes a continuation exactly once, whichever of a player's callback and
/// a backstop timer gets there first. A LOCK, because the callback comes on
/// the player's own thread.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume()
    }
}
