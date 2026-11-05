import SwiftUI

@main
struct AgentsApp: App {
    // The one part of remote notifications SwiftUI has no answer for - see
    // AppDelegate in PushRegistrar.swift.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The Deck faces are registered at runtime from the bundled .ttf
        // files, before the first view asks for one - a font requested before
        // this runs falls back to the system face without a word.
        Deck.registerFonts()
        // Before HubToken.shared's first Keychain read, which RootView's
        // first body evaluation triggers. On a phone that already has Rack
        // Control, this is what makes Agents open straight into a chat
        // instead of asking for a token that was already given.
        TokenStore.migrateToSharedGroup()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Auto / Cream / Dark from the foot of the chats drawer,
                // stamped on the WINDOW so system chrome (menus, the keyboard)
                // flips with the content - see DeckTheme in DeckCream.swift.
                .deckTheme()
                // ONE tint for the whole app - Deck's accent-ink, the orange
                // that passes as text - so the few system controls left (the
                // agent menu's rows, text selection, the spinner) do not
                // render in a system blue that appears nowhere else on the rack.
                .tint(Deck.accentInk)
                // "Hey Atlas" listens only while the app is on screen.
                .onChange(of: scenePhase, initial: true) {
                    // Background time for turns in flight on the way out; an
                    // immediate re-attach for each on the way back.
                    LiveTurns.shared.scene(scenePhase)
                    HeyAtlas.shared.scene(active: scenePhase == .active)
                    // AGAIN ON EVERY ACTIVATION, not only at launch. A cold
                    // launch by the voice intent on a locked phone can do
                    // neither (see TokenStore.migrateToSharedGroup and
                    // HubToken.refresh), and a resumed app never launches
                    // again. Both are one attributes query and one read when
                    // there is nothing to do.
                    if scenePhase == .active {
                        TokenStore.migrateToSharedGroup()
                        HubToken.shared.refresh()
                    }
                    // A LIVE ACTIVITY WITH NO SESSION BEHIND IT is one iOS
                    // left when it killed the app mid-turn: it would say
                    // "Thinking…" on the lock screen for hours. On screen and
                    // idle, nothing is running, so none should be up - the
                    // last session's short dwell goes too, and the chat shows
                    // the same answer.
                    if scenePhase == .active, VoiceSession.shared.phase.isIdle {
                        VoiceActivity.shared.endAll()
                    }
                }
        }
    }
}

/// Lock, then token, then the chat. NO TAB BAR - this app is one thing, which
/// is the entire reason it was split out of Rack Control.
///
/// NO BIOMETRIC GATE, unlike Rack Control - and NOT because this app is the
/// weaker credential. It is the stronger one. Since 2026-09-21 Atlas's Claude
/// runs with bypassPermissions and SSH to every node, so a message sent from
/// here can restart, delete or reconfigure anything on the rack. And since
/// 2026-09-22 the token is readable while the phone is LOCKED, from the first
/// unlock after a restart (`AfterFirstUnlockThisDeviceOnly`, see TokenStore),
/// so the voice intent can ask Atlas from the lock screen; the device passcode
/// no longer stands between a locked phone and the token. Both are
/// deliberate trade-offs.
///
/// The token prompt STAYS. It is not a gate - it is the only way to give the
/// app a credential it does not have, and without it a tokenless install is
/// simply a dead screen.
///
/// THE TOKEN IS OBSERVED, NOT COPIED. `HubToken.shared.needsToken` turns true
/// the moment the hub answers 401 (a rotated token), and this view drops back
/// to the token screen on its own; a locked Keychain never turns it true. A
/// `@State` seeded once at launch is what used to leave a rejected app stuck
/// on "That token was rejected." with no field to paste the new one into.
struct RootView: View {
    private let hub = HubToken.shared

    /// Demo mode never touches the network or the Keychain, so it decides
    /// this from its own flag rather than from `hub`.
    private var needsToken: Bool {
        DemoMode.isActive ? DemoMode.showsTokenEntry : hub.needsToken
    }

    var body: some View {
        if needsToken {
            TokenEntryView()
        } else {
            // Opens on a chat, not a list - see ChatShell. The conversation
            // list is behind the hamburger now.
            ChatShell()
                // HERE, NOT IN init(). This branch is reached only once a hub
                // token exists - or after a launch that found the Keychain
                // locked, when the item is there but unread; either way there
                // is a token. So the permission prompt lands on someone who
                // has seen what the app is and has a hub to be notified BY. At
                // launch it would be the first thing a new install ever showed,
                // ahead of the token screen, and iOS asks exactly once - a
                // reflexive "no" is a trip to Settings with no way back from
                // inside the app.
                //
                // A `.task` RE-RUNS whenever this branch reappears, which is
                // wanted: re-asking APNs is how a token that changed under a
                // restore or an OS update gets re-registered. `PushRegistrar`
                // carries the guard that keeps two overlapping runs from each
                // POSTing the same token.
                //
                // Not in demo mode: a screenshot run must not raise the
                // notification prompt over the screen it is photographing.
                .task { if !DemoMode.isActive { await PushRegistrar.shared.enable() } }
        }
    }
}
