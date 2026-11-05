// Agents/Voice/AtlasShortcuts.swift
import AppIntents

/// "Hey Siri, talk to Atlas" with no setup.
///
/// `.applicationName` IS "Agents" OR "Atlas". Apple requires the app's name in
/// every App Shortcut phrase; the token matches the display name AND every
/// app name synonym, and "Atlas" is one - `INAlternativeAppNames` in
/// Agents/Info.plist. So each phrase below works both ways ("Talk to Agents",
/// "Talk to Atlas"), and the bare one is "Hey Siri, Atlas".
///
/// BACK TAP DOES NOT LIST IT. Back Tap offers only shortcuts saved in the
/// user's own library, never an app's App Shortcuts - so on a phone with no
/// Action Button it takes one manual step: Shortcuts > + > add the Agents
/// "Talk to Atlas" action > save, then Settings > Accessibility > Touch >
/// Back Tap > Double Tap picks that saved shortcut. That saved shortcut runs
/// `ListenIntent` (background, no app switch); Siri runs `TalkToAtlasIntent`,
/// which opens the app when the phone is unlocked.
struct AtlasShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToAtlasIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "\(.applicationName)",
                "Hey \(.applicationName)",
                "Ask \(.applicationName)",
                "Chat with \(.applicationName)",
                "Start \(.applicationName)",
            ],
            shortTitle: "Talk to Atlas",
            systemImageName: "waveform")
    }
}
