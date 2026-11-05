// Agents/Voice/HeyAtlas.swift
import AVFoundation
import Foundation
import LiveKitWakeWord
import UIKit
import os

/// "Hey Atlas", while the app is on screen and the toggle is on.
///
/// FOREGROUND ONLY, by design and by iOS: a backgrounded app that is not
/// already recording loses the mic. The always-on version is Cortana's job, on
/// a home node, with this same model file.
///
/// THE SCREEN STAYS ON while this is armed, so a phone on a car mount does not
/// auto-lock thirty seconds in and quietly stop listening.
///
/// ONE AUDIO SESSION, TWO OWNERS. The wake mic DEACTIVATES the shared audio
/// session when it stops, and its stop is not immediate: it waits for the
/// scorer to finish first. So nothing else opens the mic until that stop has
/// landed: a hit stops the wake mic before it starts a session, and a session
/// started any other way waits on `release` before its mic opens. Otherwise
/// the late deactivation lands under the voice session's fresh engine, and
/// the question is never heard.
@Observable @MainActor
final class HeyAtlas {
    static let shared = HeyAtlas()

    /// Tuned on the phone in Task 17. Higher means fewer false wakes and more
    /// missed ones.
    static let threshold: Float = 0.5

    /// The trained model (Task 15). nil in a build without it: nothing
    /// listens, and the drawer's toggle is off and says why.
    static let modelURL = Bundle.main.url(forResource: "hey_atlas", withExtension: "onnx")
    static var installed: Bool { modelURL != nil }

    var enabled: Bool = UserDefaults.standard.bool(forKey: "voice.heyAtlas") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "voice.heyAtlas")
            update()
        }
    }

    /// Read afresh at every `update`, and kept for the drawer's footnote.
    /// NEVER ASKED FOR FROM HERE - see `note`.
    private(set) var micPermission = AVAudioApplication.shared.recordPermission

    @ObservationIgnored private var active = false
    @ObservationIgnored private let runs = WakeRuns()
    /// Built once, the first time it is wanted, and kept for every run after:
    /// building it is the expensive part, and a wake mic is cheap.
    @ObservationIgnored private var model: WakeWordModel?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var restart: Task<Void, Never>?
    /// Arms again a while after a run gave up by itself - see `gaveUp`.
    @ObservationIgnored private var rearm: Task<Void, Never>?
    @ObservationIgnored private var backoff = WakeBackoff()

    private init() {
        if Self.modelURL == nil {
            Logger.voice.notice("Hey Atlas: hey_atlas.onnx is not in this build, so it will not listen")
        }
        watchAudio()
    }

    /// Under the drawer's toggle: why it cannot do what it says, or nil.
    ///
    /// THE MIC IS NOT ASKED FOR HERE. A prompt thrown up by a toggle or at
    /// launch is a prompt answered "no" by reflex; the composer mic's first
    /// tap asks, and the session it starts ends in `update`, which arms this.
    var note: String? {
        if !Self.installed { return "The wake-word model isn't in this build." }
        guard enabled else { return nil }
        switch micPermission {
        case .granted: return nil
        case .undetermined: return "Tap the mic once to allow the microphone."
        default: return "Allow the microphone for Agents in Settings."
        }
    }

    /// From the app's scene phase.
    func scene(active: Bool) {
        self.active = active
        update()
    }

    /// From every VoiceSession phase change - see VoiceLive.
    func sessionChanged() { update() }

    /// Returns once no wake mic holds the audio session. The voice session
    /// awaits this before its mic opens - see `VoiceSession.beforeMic`.
    ///
    /// By then the session's first phase has already stopped the run, through
    /// `sessionChanged`; this waits for that stop to have LANDED. NEVER WAITS
    /// ON THE MODEL LOADING, which is not part of a run - see `load` - so the
    /// composer mic is never held up by it.
    func release() async {
        await runs.release()
    }

    /// On, and able to be. A toggle that cannot listen - no model in this
    /// build, no mic allowed yet - must not keep the screen awake for nothing.
    private var on: Bool { enabled && Self.installed && micPermission == .granted }

    private var listens: Bool {
        WakeGate.listens(enabled: on, active: active, idle: VoiceSession.shared.phase.isIdle)
    }

    private func update() {
        let permission = AVAudioApplication.shared.recordPermission
        if permission != micPermission {
            micPermission = permission
            Logger.voice.notice("Hey Atlas: the mic is \(permission == .granted ? "allowed" : "not allowed", privacy: .public)")
        }
        UIApplication.shared.isIdleTimerDisabled = on && active
        if listens { start() } else { runs.stop() }
    }

    /// Arms a wake mic, once the model is loaded.
    private func start() {
        guard !runs.running, let url = Self.modelURL else { return }
        guard let model else { return load(url) }
        runs.start { [weak self] in await self?.listen(model) }
    }

    /// Builds the model OFF THE MAIN ACTOR: three ONNX sessions handed to
    /// CoreML to compile is long enough to hitch the UI. Asks `update` again
    /// once built, since whatever wanted it may not any more.
    ///
    /// A MODEL THAT WILL NOT LOAD is logged and not retried from here - the
    /// file in the bundle is not going to change. The next scene or session
    /// change tries once more.
    private func load(_ url: URL) {
        guard loading == nil else { return }
        loading = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                Result { try WakeWordModel(models: [url], sampleRate: WakeWordModel.modelSampleRate) }
            }.value
            guard let self else { return }
            self.loading = nil
            switch built {
            case .success(let model):
                self.model = model
                self.update()
            case .failure(let error):
                Logger.voice.error("Hey Atlas: the model would not load: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// One run: a fresh wake mic on the model, until a hit or until the run
    /// is stopped.
    private func listen(_ model: WakeWordModel) async {
        let mic = WakeMic(model: model, threshold: Self.threshold) { [weak self] in
            self?.backoff.reset()
        }
        do {
            try mic.start()
        } catch {
            Logger.voice.error("Hey Atlas: the mic would not start: \(String(describing: error), privacy: .public)")
            // A half start - the session active, a scorer running - is
            // undone by `stop`.
            await mic.stop()
            if !Task.isCancelled { gaveUp() }
            return
        }
        // Ends at the first hit; when the run is stopped, since a stopped
        // run's task is cancelled and a cancelled `for await` ends; or when
        // the mic gave up after a route change.
        var heard = false
        for await _ in mic.hits {
            heard = true
            break
        }
        // LET GO OF THE SESSION BEFORE ANYTHING ELSE TAKES IT - the reason
        // is in the type's comment. Every way out of a run passes here.
        await mic.stop()
        guard !Task.isCancelled else { return }
        guard heard else { return gaveUp() }
        // Unless something changed while it let go: the app left the screen,
        // the toggle went off, or the composer mic started a session.
        guard listens else { return }
        VoiceSession.shared.trigger(AtlasVoice.shared)
    }

    /// A RUN THAT ENDED BY ITSELF, with no hit and nobody stopping it: the
    /// mic would not start, or would not come back after a route change.
    /// Left there, it is deaf with the toggle on and the screen awake until
    /// something else happens to the app. So it arms again - later each time
    /// it gives up again, so a mic that stays away is not retried in a loop,
    /// and back to soon once a run scores (`WakeBackoff`). Through `update`,
    /// so still only where `WakeGate` says; and not over a run that some
    /// other change has started in the meantime.
    private func gaveUp() {
        let delay = backoff.next()
        Logger.voice.notice("Hey Atlas: the mic gave up, trying again in \(delay.components.seconds, privacy: .public) s")
        rearm?.cancel()
        rearm = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.runs.running else { return }
            self.update()
        }
    }

    /// AN INTERRUPTION (a call, Siri, an alarm) OR A MEDIA-SERVICES RESET
    /// leaves the wake mic deaf, still looking armed. So after either, a run
    /// that should be going is replaced with a fresh one. Route changes -
    /// AirPods, the car - are the wake mic's own business: its engine says
    /// when its input changed, and it restarts itself (`WakeMic.restart`).
    ///
    /// MUSIC NO LONGER INTERRUPTS IT. The wake mic's session mixes with other
    /// audio, so Spotify starting again is not an interruption at all.
    private func watchAudio() {
        let center = NotificationCenter.default
        let interruptions = center.notifications(named: AVAudioSession.interruptionNotification)
        let resets = center.notifications(named: AVAudioSession.mediaServicesWereResetNotification)
        Task { [weak self] in
            for await note in interruptions where note.interruption == .ended {
                self?.restartSoon("an interruption ended")
            }
        }
        Task { [weak self] in
            for await _ in resets { self?.restartSoon("media services were reset") }
        }
    }

    /// Half a second after the last of a burst, and only if a run should be
    /// going at all. The new run starts once the old one has let go;
    /// `WakeRuns` sees to that.
    private func restartSoon(_ why: String) {
        restart?.cancel()
        restart = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.listens else { return }
            Logger.voice.notice("Hey Atlas: listening afresh, \(why, privacy: .public)")
            self.runs.stop()
            self.update()
        }
    }
}

/// How long HeyAtlas waits to arm again after a run gave up by itself:
/// five seconds, doubling each time it gives up again, up to a minute. Back
/// to five once a run scores - the mic and the model both worked.
struct WakeBackoff {
    static let first: Duration = .seconds(5)
    static let longest: Duration = .seconds(60)

    private var delay = first

    /// This wait, and the next one doubled.
    mutating func next() -> Duration {
        defer { delay = min(delay * 2, Self.longest) }
        return delay
    }

    mutating func reset() { delay = Self.first }
}

/// The wake mic, one run at a time.
///
/// A RUN STARTS ONLY ONCE THE ONE BEFORE IT HAS ENDED, and `release` returns
/// only once the latest has. A wake mic's stop is asynchronous - it waits
/// for its scorer to finish - and its last act is to deactivate the shared
/// audio session; two runs overlapping, or a run still winding down under
/// the voice session's mic, would have that deactivation land on whoever
/// started second. Two runs overlapping would also score on one model at
/// once, which it does not allow.
///
/// A run is a closure that listens until its task is cancelled, then lets go
/// of the mic and returns. Apart from HeyAtlas so the order can be tested
/// without a mic.
@MainActor
final class WakeRuns {
    /// A run is wanted: started, and neither stopped nor ended since.
    private(set) var running = false
    /// The latest run. KEPT AFTER IT IS STOPPED, so the next run and
    /// `release` can wait for it to finish letting go.
    private var last: Task<Void, Never>?

    func start(_ run: @escaping @MainActor @Sendable () async -> Void) {
        guard !running else { return }
        running = true
        let previous = last
        last = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await run()
            // ENDED BY ITSELF - a mic that would not start - rather than
            // stopped: not running, so the next `start` tries again. After a
            // `stop` this is left alone, as a newer run may have set it.
            if !Task.isCancelled { self?.running = false }
        }
    }

    /// Cancels the run, which lets go of the mic on its own a moment later.
    /// `release` is how to wait for that.
    func stop() {
        guard running else { return }
        running = false
        last?.cancel()
    }

    /// Stops the run, and returns once it - and so every run before it - has
    /// ended.
    func release() async {
        stop()
        await last?.value
    }
}
