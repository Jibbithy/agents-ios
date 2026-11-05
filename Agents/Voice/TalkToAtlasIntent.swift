// Agents/Voice/TalkToAtlasIntent.swift
import AppIntents

/// "Hey Siri, talk to Atlas" - the Siri shortcut, and the action a personal
/// Shortcut named "Atlas" runs.
///
/// THE SAME SESSION AS `ListenIntent` (Back Tap, the control), through
/// `ListenIntent.listen`. The one difference is where it runs: this OPENS THE
/// APP when it can, so the conversation is on screen, and falls back to the
/// background - with the Live Activity, exactly like Back Tap - when it
/// cannot, i.e. a locked phone. `ListenIntent` itself stays background-only:
/// a Back Tap from inside another app must not pull you out of it.
///
/// AN `AudioRecordingIntent` + `LiveActivityIntent` for that locked fallback,
/// for the same reasons `ListenIntent` is one.
///
/// APP ONLY. The widget extension never names this intent, so unlike
/// `ListenIntent` it is not compiled there.
struct TalkToAtlasIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Open Atlas Voice"
    static let description: IntentDescription? = IntentDescription(
        "Opens Agents and starts a hands-free conversation with Atlas.")

    /// Same decision as `ListenIntent`: no Face ID on the locked path.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// FOREGROUND WHENEVER POSSIBLE, BACKGROUND AS NEEDED - Apple's wording for
    /// exactly this pair. Unlocked, Siri opens the app straight into
    /// listening; locked, it runs in the background behind the Live Activity
    /// instead of asking for Face ID first. iOS 26 only; before that the
    /// intent runs in the background, as `ListenIntent` does.
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate), .background]

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ListenIntent.listen()
        return .result()
    }
}
