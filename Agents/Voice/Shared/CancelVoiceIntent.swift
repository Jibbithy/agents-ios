// Agents/Voice/Shared/CancelVoiceIntent.swift
import AppIntents

/// The Live Activity's Cancel button. Runs in the app's process, like
/// `ListenIntent`; the extension compiles it only so the button can name it.
struct CancelVoiceIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Atlas"
    /// A button's action, not something to offer in the Shortcuts app.
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
            // AN IDLE SESSION BEHIND A LIVE ACTIVITY means iOS killed the app
            // mid-turn and this press relaunched it: there is nothing to cancel,
            // but the activity would sit on the lock screen for hours saying
            // "Thinking…". Take it down.
            if VoiceSession.shared.phase.isIdle {
                VoiceActivity.shared.endAll()
            } else {
                VoiceSession.shared.cancel()
            }
        #endif
        return .result()
    }
}
