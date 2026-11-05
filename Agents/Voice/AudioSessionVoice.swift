// Agents/Voice/AudioSessionVoice.swift
import AVFoundation
import UIKit
import os

/// The shared audio session and the one mic, on for one voice session.
///
/// THE MIC STAYS OPEN FOR THE WHOLE SESSION, not only while listening, and
/// that is what keeps the app alive. An app with the `audio` background mode
/// is kept running only while it is actually recording or playing; a Claude
/// Code turn can think in silence for minutes, and an active-but-idle session
/// is suspended within seconds - the stream dies and the answer is never read.
/// The tap's buffers go to `MicFeed`, which drops them unless the Transcriber
/// is listening. For the same reason the mic is RESTARTED whenever something
/// stops it mid-session - see `restart`.
///
/// `.duckOthers` turns Spotify down rather than stopping it, and
/// `.notifyOthersOnDeactivation` brings it back up afterwards.
/// `.allowBluetoothHFP` is what makes the AIRPODS' mic the one listening;
/// A2DP alone would play through the AirPods and listen through a phone in a
/// pocket. The cost is that the AirPods play at call quality for the session,
/// the answer included - the price of their mic, and paid on purpose.
///
/// ONE ENGINE FOR THE MIC AND THE VOICE, with voice processing on: echo
/// cancellation takes out of the mic whatever the same engine played, which
/// is what lets the mic go on listening while Atlas speaks. Every word is
/// played through `output` for that reason.
@MainActor
final class AudioSessionVoice: VoiceAudio {
    /// Where all speech plays: on `engine`, so voice processing can take it
    /// back out of the mic. See `VoiceOutput`.
    let output = VoiceOutput()
    /// Echo cancellation is taking Atlas's own voice back out of the mic
    /// RIGHT NOW. False whenever the engine is not running - between
    /// sessions, and while an interruption holds it - as well as when voice
    /// processing would not turn on: then what the mic hears while Atlas
    /// speaks may be Atlas, and nothing should believe it.
    var echoCancelled: Bool { echoCancelling && engine?.isRunning == true }
    /// Voice processing is on for the engine of the moment, running or not.
    private var echoCancelling = false
    /// Turned off for the rest of the session when the mic restarts over and
    /// over - see `RestartBudget`.
    private var voiceProcessing = true
    private var restarts = RestartBudget()
    /// The engine running the tap. A FRESH ONE EVERY TIME THE MIC STARTS, at
    /// the start of a session and at every restart: an engine that was
    /// running before a route change (AirPods connecting) can go on reporting
    /// the old sample rate, and a tap installed with a rate that is not the
    /// hardware's raises an exception Swift cannot catch.
    private var engine: AVAudioEngine?
    /// Restarts the mic when `engine`'s configuration changes. One per engine.
    private var changes: Task<Void, Never>?
    /// Tells the session when an interruption begins, and restarts the mic
    /// when it ends. One per session.
    private var interruptions: Task<Void, Never>?
    /// An interruption began - a phone call, an alarm, Siri - while a session
    /// was running. VoiceLive points it at `VoiceSession.interrupted`.
    var onInterrupted: (() -> Void)?
    /// The one second try after a restart that failed - see `restart`.
    private var retry: Task<Void, Never>?
    /// The one second try at switching the session off - see `deactivate`.
    private var deactivation: Task<Void, Never>?
    /// Counts `begin`s, so a late second try at switching the LAST session
    /// off can tell that a new one has started since.
    private var began = 0

    private static let options: AVAudioSession.CategoryOptions =
        [.duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]

    func begin() async throws {
        began += 1
        voiceProcessing = true
        restarts = RestartBudget()
        // FIRST OF ALL, before anything here can fail: a failure is read
        // aloud, and the reading needs somewhere to play. Until the mic's
        // engine is attached, and if it never is, that is an engine of the
        // output's own. See `VoiceOutput.open`.
        output.open()
        let session = AVAudioSession.sharedInstance()
        // THE CATEGORY FIRST, before anything here can fail. A failure is
        // read aloud, and speech plays in whatever category the session has:
        // on a cold launch from the lock screen that is still `.soloAmbient`,
        // which the lock silences - "Open Agents and tap the mic once" said
        // to nobody. It does nothing else while the session is inactive.
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: Self.options)
        } catch {
            Logger.voice.error("Voice: the category was refused: \(error.domainAndCode, privacy: .public)")
            throw VoiceError.micBusy
        }

        // Before the mic opens: from a locked phone (a `.background` launch)
        // the prompt cannot appear, so an unanswered one is a no. NOT
        // `== .active`, which an app still `.inactive` from an alert fails.
        switch AVAudioApplication.shared.recordPermission {
        case .granted: break
        case .undetermined:
            let state = UIApplication.shared.applicationState
            guard state != .background else {
                Logger.voice.notice("Voice: the mic is not allowed yet, and the app is in the background")
                throw VoiceError.notAllowed
            }
            guard await AVAudioApplication.requestRecordPermission() else {
                Logger.voice.notice("Voice: the mic was refused at the prompt (app \(state.logged, privacy: .public))")
                throw VoiceError.notAllowed
            }
        default:
            Logger.voice.notice("Voice: the mic is turned off for Agents in Settings")
            throw VoiceError.notAllowed
        }

        // A FAILED BEGIN UNDOES ITSELF AT ONCE, whichever step failed,
        // through `shutDown`: the session's own `end()` comes only after the
        // failure has been read, and until then a watcher left running would
        // restart a mic nobody is using.
        //
        // BUT THE AUDIO SESSION STAYS ON, and the category with it, because
        // the failure is about to be read aloud on it. Switched off here, it
        // would be switched straight back on for the reading, and Spotify
        // would come up and duck again for one sentence.
        do {
            try session.setActive(true)
            watchInterruptions()
            // AFTER the category is set: only then does the input node have a
            // real format to tap.
            try run(cancellingEcho: true)
        } catch {
            // THE REAL REASON, before it becomes "Mic busy." - a call holding
            // the mic, a session that would not switch on and an engine that
            // would not start all say the same thing aloud.
            Logger.voice.error("Voice: the mic would not start: \(error.domainAndCode, privacy: .public)")
            shutDown()
            throw VoiceError.micBusy
        }
    }

    func end() {
        shutDown()
        // Nothing more plays until the next `begin`: a chunk arriving late
        // would otherwise start an engine of the output's own and switch
        // this session back on with nobody left to switch it off.
        output.close()
        deactivate()
    }

    /// Everything but the switch-off: the watchers, the mic's engine, and
    /// whatever the output was playing on.
    private func shutDown() {
        retry?.cancel()
        retry = nil
        changes?.cancel()
        changes = nil
        interruptions?.cancel()
        interruptions = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        // Stopping the output's own engine too, if a failure was said on
        // one: BEFORE the switch-off, which running audio would refuse.
        output.detach()
        echoCancelling = false
        MicFeed.shared.route(to: nil)
    }

    /// Switches the session off, which brings Spotify back up - and ONCE
    /// MORE, 400 ms later, if that is refused. `end` comes straight after
    /// `speak` returns, when the output can still be holding the hardware,
    /// and the session then refuses with "is busy" (560030580). Left there,
    /// other audio stays ducked until the next voice session.
    ///
    /// ONLY IF THE SESSION IS STILL THIS ONE'S by then: no new voice session
    /// has begun, and the category still ducks. The wake word re-arms the
    /// moment the session goes idle, on a mixable category of its own, and a
    /// late switch-off would take the session away under its mic.
    private func deactivate() {
        deactivation?.cancel()
        deactivation = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Logger.voice.notice("Voice: the session would not switch off (\(error.domainAndCode, privacy: .public)), trying again")
            let session = began
            deactivation = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                let audio = AVAudioSession.sharedInstance()
                guard !Task.isCancelled, let self, self.began == session,
                    audio.categoryOptions.contains(.duckOthers)
                else { return }
                do {
                    try audio.setActive(false, options: .notifyOthersOnDeactivation)
                    Logger.voice.notice("Voice: the session switched off on the second try")
                } catch {
                    Logger.voice.error("Voice: the session would not switch off again: \(error.domainAndCode, privacy: .public)")
                }
            }
        }
    }

    /// Opens the mic on a fresh engine, with the voice's player on it. WATCHED
    /// BEFORE IT STARTS, so a configuration change that lands while it is
    /// starting is not missed.
    ///
    /// An engine that will not start with echo cancellation on gets ONE more
    /// try, a fresh one without it: the mic as it was before, rather than
    /// "Mic busy." on a route voice processing does not suit.
    ///
    /// AND NOTHING IS LEFT ATTACHED TO AN ENGINE THAT FAILED. The output
    /// lets go of it, so a failure can still be read aloud - on an engine of
    /// the output's own, since by then there is no mic to speak through.
    private func run(cancellingEcho: Bool) throws {
        echoCancelling = false
        let engine = AVAudioEngine()
        self.engine = engine
        watchChanges(of: engine)
        do {
            let (format, cancelled) = try Self.input(of: engine, cancellingEcho: cancellingEcho)
            echoCancelling = cancelled
            // THE OUTPUT IN THE INPUT'S FORMAT while voice processing is on:
            // the two ends of it must match (AVAudioIONode.h). Left to
            // itself, the engine connects its main mixer to the output at
            // 44.1 kHz stereo (seen in the Simulator) and changes the output
            // node to that, away from the input's mono at 48 kHz.
            output.attach(to: engine, feeding: cancelled ? format : nil)
            do {
                try Self.start(engine, tapping: format)
                output.engineStarted()
            } catch  where cancelled {
                Logger.voice.error("Voice: the mic would not start with echo cancellation (\(error.domainAndCode, privacy: .public)), trying without it")
                // THE FAILED ENGINE LET GO OF FIRST: voice processing is one
                // unit across both its ends, and a second engine starting
                // while it still holds one is asking for the same failure.
                engine.stop()
                try? engine.inputNode.setVoiceProcessingEnabled(false)
                try run(cancellingEcho: false)
            }
        } catch {
            echoCancelling = false
            output.detach()
            throw error
        }
    }

    /// Brings the mic back after something stopped it mid-session. Two
    /// things do, and either would otherwise end the tap, and with it the
    /// background keep-alive, so the app is suspended mid-turn:
    /// - A CONFIGURATION CHANGE - the input's sample rate or channel count
    ///   changed, e.g. AirPods connecting. The engine stops itself (see
    ///   AVAudioEngine.h).
    /// - AN INTERRUPTION - a phone call, an alarm. When it ends, the session
    ///   has to be activated again before any engine will run.
    /// Either way the old engine is thrown away and a fresh one started - see
    /// `engine` for why a kept one is not safe to tap again.
    ///
    /// IF THE MIC WILL NOT COME BACK, THERE IS NOTHING TO DO BUT LEAVE IT. A
    /// listen in progress runs on to its no-speech timeout; a turn in
    /// progress carries on on the hub, and if the app is suspended before
    /// the answer arrives, the answer is still in the chat to read. A later
    /// interruption ending tries again.
    private func restart(reactivating: Bool) {
        // No engine: the session is over.
        guard let old = engine else { return }
        // Still running, it rode the change out - and a fresh engine whose
        // own start posts a change cannot restart itself forever.
        if !reactivating, old.isRunning { return }
        Logger.voice.notice("Voice: restarting the mic after \(reactivating ? "an interruption" : "a configuration change", privacy: .public)")
        changes?.cancel()
        changes = nil
        old.stop()
        old.inputNode.removeTap(onBus: 0)
        // What was playing went with the old engine: `drained` returns now,
        // rather than waiting on callbacks that engine will never make.
        output.detach()
        echoCancelling = false
        // A MIC THAT RESTARTS OVER AND OVER comes back without echo
        // cancellation: voice processing reconfigures the engine as it
        // starts, and a configuration change of its own would restart it
        // again, for as long as the session lasted.
        if voiceProcessing, !restarts.allow(at: ProcessInfo.processInfo.systemUptime) {
            voiceProcessing = false
            Logger.voice.error(
                """
                Voice: the mic has restarted \(RestartBudget.limit + 1, privacy: .public) times in \
                \(RestartBudget.window, format: .fixed(precision: 0), privacy: .public) s; \
                bringing it back without echo cancellation for the rest of this session
                """)
        }
        if reactivating {
            do { try AVAudioSession.sharedInstance().setActive(true) } catch {
                Logger.voice.error("Voice: the session would not come back: \(error.domainAndCode, privacy: .public)")
                return
            }
        }
        do { try run(cancellingEcho: voiceProcessing) } catch {
            Logger.voice.error("Voice: the mic would not restart: \(error.domainAndCode, privacy: .public)")
            retryOnce()
        }
    }

    /// ONE more try at the mic, half a second after a restart failed. A route
    /// still settling (AirPods half-connected) can refuse the first, and an
    /// engine that never started may never post the change that would
    /// otherwise retry it - leaving the mic off for the rest of the session.
    /// Only if nothing has moved on since: `engine` is still the failed one,
    /// so neither `end` nor another restart has run.
    private func retryOnce() {
        retry?.cancel()
        let failed = engine
        retry = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, let failed, self.engine === failed else { return }
            do {
                try self.run(cancellingEcho: self.voiceProcessing)
                Logger.voice.notice("Voice: the mic came back on the second try")
            } catch {
                Logger.voice.error("Voice: the mic would not restart again: \(error.domainAndCode, privacy: .public)")
            }
        }
    }

    /// Main-actor tasks over async sequences, cancelled in `end` and on each
    /// restart, so every restart happens on the main actor - never on the
    /// queue the engine posts from, where tearing it down could deadlock.
    private func watchChanges(of engine: AVAudioEngine) {
        changes?.cancel()
        let notes = NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange, object: engine)
        changes = Task { [weak self] in
            for await _ in notes {
                guard !Task.isCancelled else { return }
                self?.restart(reactivating: false)
            }
        }
    }

    private func watchInterruptions() {
        interruptions?.cancel()
        let notes = NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification)
        interruptions = Task { [weak self] in
            for await note in notes {
                guard !Task.isCancelled else { return }
                switch note.interruption {
                case .began:
                    Logger.voice.notice("Voice: interrupted")
                    self?.onInterrupted?()
                case .ended:
                    self?.restart(reactivating: true)
                default:
                    break
                }
            }
        }
    }

    /// A fresh engine's input, echo cancelled if it will be, and the format
    /// to tap it in.
    ///
    /// VOICE PROCESSING FIRST, before anything else touches the engine. It
    /// can only be switched while the engine is stopped; it switches the
    /// output node too, as both ends run as one voice-processing unit
    /// (AVAudioIONode.h); and it changes the input's format. So the formats
    /// are read AFTER it, and the output is attached after this returns.
    ///
    /// If the formats will not do with it on, it is switched back off and
    /// they are read again: a mic without echo cancellation beats "Mic busy.".
    private static func input(
        of engine: AVAudioEngine,
        cancellingEcho: Bool
    ) throws -> (format: AVAudioFormat, echoCancelled: Bool) {
        let input = engine.inputNode
        if cancellingEcho, cancelEcho(on: input), tapFormat(of: input) == nil {
            Logger.voice.error("Voice: nothing to tap with echo cancellation on, trying without it")
            do { try input.setVoiceProcessingEnabled(false) } catch {
                Logger.voice.error("Voice: echo cancellation would not turn off: \(error.domainAndCode, privacy: .public)")
            }
        }
        guard let format = tapFormat(of: input) else { throw VoiceError.micBusy }
        // FROM THE NODE, not from what was asked of it: the truth even when
        // the switch back off failed.
        let cancelled = input.isVoiceProcessingEnabled
        Logger.voice.notice(
            """
            Voice: tapping \(format.channelCount, privacy: .public) channels at \
            \(format.sampleRate, privacy: .public) Hz, echo cancellation \(cancelled ? "on" : "off", privacy: .public)
            """)
        return (format, cancelled)
    }

    /// Voice processing on: echo cancellation, and with it the ducking of
    /// other audio set as mild as it goes. False, logged, if it will not.
    private static func cancelEcho(on input: AVAudioInputNode) -> Bool {
        do { try input.setVoiceProcessingEnabled(true) } catch {
            Logger.voice.error("Voice: no echo cancellation: \(error.domainAndCode, privacy: .public)")
            return false
        }
        // VOICE PROCESSING DUCKS OTHER AUDIO, harder than `.duckOthers`, for
        // as long as the engine runs, and that is the whole session. The
        // mildest level; "advanced" ducks only while someone is speaking.
        input.voiceProcessingOtherAudioDuckingConfiguration =
            .init(enableAdvancedDucking: true, duckingLevel: .min)
        return true
    }

    /// The format to tap `input` in, or nil if a tap would crash.
    ///
    /// CHECKED AGAINST THE HARDWARE'S FORMAT - the input node's INPUT format,
    /// as AVAudioEngine.h says - as it is AFTER voice processing was set.
    /// Zero channels or rate means there is no input (a call holding the
    /// mic, a device with none), and a tap then raises an exception Swift
    /// cannot catch; so does a tap whose rate is not the hardware's. On a
    /// fresh engine the two formats agree, and if they ever do not, "Mic
    /// busy." is better than a crash.
    private static func tapFormat(of input: AVAudioInputNode) -> AVAudioFormat? {
        let hardware = input.inputFormat(forBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard hardware.channelCount > 0, hardware.sampleRate > 0,
            format.sampleRate == hardware.sampleRate
        else {
            Logger.voice.error(
                """
                Voice: no input to tap (\(hardware.channelCount, privacy: .public) channels at \
                \(hardware.sampleRate, privacy: .public) Hz, tap at \(format.sampleRate, privacy: .public) Hz)
                """)
            return nil
        }
        return format
    }

    /// Taps a fresh engine's input in `format` and starts it. Undoes its own
    /// tap if the start fails.
    private static func start(_ engine: AVAudioEngine, tapping format: AVAudioFormat) throws {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap())
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// The mic tap. NONISOLATED ON PURPOSE: the engine calls it on a
    /// real-time audio thread, and a closure written inside this @MainActor
    /// class would be inferred main-actor-isolated - which Swift 6 checks at
    /// run time, and traps on, at the first buffer.
    nonisolated private static func tap() -> AVAudioNodeTapBlock {
        { buffer, _ in MicFeed.shared.append(buffer) }
    }
}

/// The chimes and the hum play on the output, on the mic's own engine.
extension AudioSessionVoice: VoiceCues {
    func play(_ cue: Cue) async { await output.play(cue) }
    func thinking(_ on: Bool) { output.thinking(on) }
}

extension Notification {
    /// An `AVAudioSession.interruptionNotification`'s type: began or ended.
    /// nil for any other notification. Both mics watch for these - this one
    /// and the wake word's (`HeyAtlas.watchAudio`).
    var interruption: AVAudioSession.InterruptionType? {
        guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return nil }
        return AVAudioSession.InterruptionType(rawValue: raw)
    }
}

/// How often the mic may restart before it is the restarts themselves that
/// are the problem.
///
/// A RESTART IS NORMALLY A ROUTE CHANGE - AirPods connecting, a car - and
/// those come seconds apart at worst. Voice processing reconfigures the
/// engine as it starts, and if that ever posted a configuration change of
/// its own, the mic would restart itself for as long as the session lasted,
/// taking the answer being read with it every time. After the budget it comes
/// back without echo cancellation, which is how the mic ran before any of it.
struct RestartBudget {
    static let limit = 3
    static let window: TimeInterval = 5

    private var times: [TimeInterval] = []

    /// Records a restart at `now`. False once there have been more than
    /// `limit` of them inside `window`: they are feeding themselves.
    mutating func allow(at now: TimeInterval) -> Bool {
        times = times.filter { now - $0 < Self.window }
        times.append(now)
        return times.count <= Self.limit
    }
}
