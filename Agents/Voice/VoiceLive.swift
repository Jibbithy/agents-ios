// Agents/Voice/VoiceLive.swift
import Foundation

extension VoiceSession {
    /// The app's one session, on the real mic, voice and audio session. One,
    /// because there is one mic: two sessions would fight over it.
    ///
    /// EVERY PHASE GOES TO THE LIVE ACTIVITY, including sessions started from
    /// the composer: if you lock the phone mid-answer, the answer should
    /// still be on the lock screen. And swiping the activity away stops the
    /// session, as its Cancel would.
    static let shared: VoiceSession = {
        let audio = AudioSessionVoice()
        // Kokoro on atlas, and the Apple voice whenever Kokoro can't - see
        // `FallbackVoice`. Both play on the mic's own engine, so echo
        // cancellation can hear them - see `VoiceOutput`.
        let speaker = FallbackVoice(
            kokoro: KokoroVoice(output: audio.output),
            apple: AppleVoice(output: audio.output))
        let session = VoiceSession(listener: Transcriber(), speaker: speaker, audio: audio)
        session.mail = MailApprovals.shared
        // The chimes and the thinking hum, on the mic's own engine.
        session.cues = audio
        // Hands-free or single-shot, and the end phrases: the user's, read
        // at the start of each session.
        session.settings = { VoiceSettings.load() }
        // A call or an alarm cuts off a listen or a reading, but not a turn -
        // see `interrupted`.
        audio.onInterrupted = { [weak session] in session?.interrupted() }
        session.onPhase = { phase in
            VoiceActivity.shared.show(phase)
            // The wake word lets go of the mic the moment a session starts,
            // and picks it back up when the session is over.
            HeyAtlas.shared.sessionChanged()
        }
        // And the mic does not open until the letting go has LANDED.
        session.beforeMic = { await HeyAtlas.shared.release() }
        VoiceActivity.shared.onDismissed = { [weak session] in session?.cancel() }
        return session
    }()
}
