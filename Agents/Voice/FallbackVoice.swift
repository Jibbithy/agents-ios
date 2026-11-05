// Agents/Voice/FallbackVoice.swift
import Foundation
import os

/// Reads answers in Kokoro's voice, and in the Apple voice whenever Kokoro
/// can't: never silence.
///
/// - NO AUDIO WITHIN `timeout` (3 s), or a failure before any: Kokoro is
///   stopped and the Apple voice reads ALL of it. Kokoro's first chunk is
///   short enough to come back in about a second (see `SpeechChunks`), so
///   3 s means it is down, busy or unreachable.
/// - A FAILURE MIDWAY: what Kokoro had delivered plays on, and the Apple
///   voice reads the REST after it, from the chunk that failed.
///
/// Every fallback is logged with its reason. Kokoro is tried again for the
/// next answer; one reading never tries it twice, so a 401 or a locked
/// Keychain costs one quick failed request, not a loop.
@MainActor
final class FallbackVoice: Speaking {
    static let firstAudioTimeout: Duration = .seconds(3)

    private let kokoro: ChunkedSpeaking
    private let apple: Speaking
    private let timeout: Duration
    /// Counts speaks and stops, so a reading that was stopped, or replaced,
    /// does not go on to fall back.
    private var reading = 0
    private var active = Active.none

    private enum Active { case none, kokoro, apple }

    /// `timeout` is the seam for tests, which cannot wait 3 s a case.
    init(kokoro: ChunkedSpeaking, apple: Speaking, timeout: Duration = firstAudioTimeout) {
        self.kokoro = kokoro
        self.apple = apple
        self.timeout = timeout
    }

    func speak(_ text: String) async {
        // Never two readings: the first is cut off, as in AppleVoice.
        if active != .none { stop() }
        let chunks = SpeechChunks.split(text)
        guard !chunks.isEmpty else { return }
        reading += 1
        let id = reading
        active = .kokoro
        let attempt = Attempt(started: ProcessInfo.processInfo.systemUptime)
        let watchdog = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.reading == id, !attempt.heard else { return }
            attempt.timedOut = true
            self.kokoro.stop()
        }
        let failure = await kokoro.speak(chunks) {
            attempt.heard = true
            watchdog.cancel()
            let after = ProcessInfo.processInfo.systemUptime - attempt.started
            Logger.voice.notice("Voice: Kokoro's first audio after \(after, format: .fixed(precision: 2), privacy: .public) s")
        }
        watchdog.cancel()
        // Stopped, or another speak took over: nothing more to say.
        guard reading == id else { return }
        let from: Int
        if attempt.timedOut {
            from = 0
        } else if let failure {
            from = min(failure.delivered, chunks.count)
        } else {
            active = .none
            return
        }
        guard from < chunks.count else {
            active = .none
            return
        }
        if attempt.timedOut {
            Logger.voice.error("Voice: no audio from Kokoro in \(String(describing: self.timeout), privacy: .public), the Apple voice reads it")
        } else if let failure {
            let reason = String(describing: failure.reason)
            if attempt.heard {
                Logger.voice.error(
                    """
                    Voice: Kokoro failed (\(reason, privacy: .public)) with \(failure.delivered, privacy: .public) of \
                    \(chunks.count, privacy: .public) chunks delivered, the Apple voice reads the rest
                    """)
            } else {
                Logger.voice.error("Voice: Kokoro failed before any audio (\(reason, privacy: .public)), the Apple voice reads it")
            }
        }
        // ALL OF IT IS THE TEXT ITSELF, not its chunks put back together, so
        // nothing of how it was written is lost. From the middle it can only
        // be the chunks, and they lose nothing either: every run of
        // whitespace in a spoken answer is already one space (`SpokenText`).
        let rest = from == 0 ? text : chunks[from...].joined(separator: " ")
        // AFTER what Kokoro delivered, not over it: both play on the one
        // output, in the order they were scheduled.
        active = .apple
        await apple.speak(rest)
        if reading == id { active = .none }
    }

    /// The app's own words, in the Apple voice, at once.
    ///
    /// NEVER KOKORO'S. "Can't reach the rack. Is Tailscale connected?" would
    /// be fetched THROUGH that rack, and the 3 s window would run out before
    /// it could be said - after a turn that already failed slowly. This is
    /// not a rule about short text: "Yes, it's up." is an answer, and stays
    /// in Kokoro's voice.
    func say(_ text: String) async {
        if active != .none { stop() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        reading += 1
        let id = reading
        active = .apple
        await apple.speak(text)
        if reading == id { active = .none }
    }

    /// Stops whichever voice is reading, and `speak` returns without falling
    /// back: a stop is Cancel or a barge-in, and wants silence.
    func stop() {
        reading += 1
        active = .none
        kokoro.stop()
        apple.stop()
    }

    /// Kokoro's chunks while it reads; once the Apple voice has taken over,
    /// whatever of Kokoro's is still playing ahead of it, and the Apple
    /// voice's own.
    var speakingNow: [String] {
        switch active {
        case .none: []
        case .kokoro: kokoro.speakingNow
        case .apple: kokoro.speakingNow + apple.speakingNow
        }
    }

    /// One reading's try at Kokoro: shared by the watchdog and the
    /// first-audio callback, both on the main actor.
    @MainActor private final class Attempt {
        let started: TimeInterval
        var heard = false
        var timedOut = false
        init(started: TimeInterval) { self.started = started }
    }
}

/// A voice that reads an answer in chunks and, when it cannot finish, says
/// how far it got: `KokoroVoice`, or a test's fake.
@MainActor protocol ChunkedSpeaking: AnyObject {
    /// Reads `chunks` in order, calling `onFirstAudio` once, when the first
    /// of its audio is handed to the output. nil once all of it has been
    /// heard, or `stop` cut it off.
    func speak(_ chunks: [String], onFirstAudio: @escaping @MainActor () -> Void) async -> SpeechFailure?
    func stop()
    var speakingNow: [String] { get }
}

/// A reading that could not be finished, and how far it got.
struct SpeechFailure: Error, Equatable, Sendable {
    let reason: TTSError
    /// How many chunks reached the output whole. They play on; the rest,
    /// from this index, are still to be said.
    let delivered: Int
}
