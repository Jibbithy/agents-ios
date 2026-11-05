// Agents/Voice/Shared/ListenIntent.swift
import ActivityKit
import AppIntents

#if !WIDGET_EXTENSION
    import os
    import UIKit
#endif

/// Talk to Atlas - behind the Action Button, the Control Center and
/// lock-screen control, and the Shortcut Back Tap runs.
///
/// AN `AudioRecordingIntent` IS WHAT MAKES THE LOCKED PHONE WORK. It lets the
/// app record from the background, without opening, on the condition that a
/// Live Activity is showing for as long as it does - which is why `perform`
/// starts one before anything else.
///
/// AND A `LiveActivityIntent`, because it does start one: ActivityKit refuses
/// to start a Live Activity from the background for anything else. Being an
/// `AudioRecordingIntent` alone does not count.
///
/// COMPILED INTO THE WIDGET EXTENSION TOO, because the control names this
/// type. The system runs it in the APP's process; the extension's copy never
/// executes, which is what the `#if` stands in for.
struct ListenIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Talk to Atlas"
    static let description: IntentDescription? = IntentDescription("Listens, asks Atlas, and reads the answer aloud.")

    /// NO FACE ID - the user's decision on 2026-09-21, made knowing that Atlas
    /// runs with bypassPermissions and SSH to every node. Anyone holding the
    /// locked phone can use this. `.requiresAuthentication` puts a Face ID
    /// glance in front of it; that is the whole change.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// What the system shows when the intent throws.
    enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case liveActivitiesOff

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .liveActivitiesOff: "Turn on Live Activities for Agents in Settings"
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
            try await Self.listen()
        #endif
        return .result()
    }

    #if !WIDGET_EXTENSION
        /// Starts a session asking the voice chat, or presses the one already
        /// running. SHARED WITH `TalkToAtlasIntent` (Siri), so Back Tap, the
        /// control and Siri all start exactly the same session.
        @MainActor
        static func listen() async throws {
            // IN THE BACKGROUND WITH LIVE ACTIVITIES OFF, the system would stop
            // the recording the moment it began: say why instead of a dead mic.
            // In the foreground - including under Control Center, which only makes
            // the app inactive - the mic works without one. ONLY TO START: a press
            // on a session already running (a composer session, then the phone
            // locked) sends what was heard, and must not be refused.
            let phase = VoiceSession.shared.phase
            let state = UIApplication.shared.applicationState
            let activities = ActivityAuthorizationInfo().areActivitiesEnabled
            // Logged either way: a press on a locked phone has no screen, and this
            // line is what a device run shows of how it was taken.
            let refused = phase.isIdle && state == .background && !activities
            Logger.voice.notice(
                """
                ListenIntent in the app: \(refused ? "refused, Live Activities are off" : "triggering", privacy: .public) \
                (app \(state.logged, privacy: .public), phase \(phase.logged, privacy: .public), \
                Live Activities \(activities ? "on" : "off", privacy: .public))
                """)
            if refused { throw Failure.liveActivitiesOff }
            // The Live Activity starts synchronously inside `trigger`, through `onPhase`.
            VoiceSession.shared.trigger(AtlasVoice.shared)
            // Back only once the mic is open, or has failed to - see `micSettled`.
            await VoiceSession.shared.micSettled()
        }
    #endif
}
