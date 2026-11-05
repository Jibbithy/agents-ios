import Foundation

/// A fake, offline session so every screen can be looked at and screenshotted.
///
/// `simctl` can launch an app and take a screenshot and nothing else - it
/// cannot tap, type or scroll - and a real chat needs a hub token, the tailnet
/// and a live agent. Without this, the only screen a script could ever reach
/// is the token prompt.
///
/// ACTIVATED ONLY BY A LAUNCH ARGUMENT, AND ONLY IN A DEBUG BUILD. Every flag
/// below is a plain `false` in release, so each branch guarded by one is dead
/// code the optimiser removes. Nothing here touches the network, the Keychain
/// or the push registration.
///
///   xcrun simctl launch <udid> com.example.agents -AgentsDemo [flags]
///
///   (none)                  a finished conversation: tools, code, long text
///   -AgentsDemoEnds         the other endings: stopped, dropped, an error
///   -AgentsDemoBusy         a turn in flight: thinking row and Stop
///   -AgentsDemoEmpty        a fresh chat with nothing in it
///   -AgentsDemoFailed       a resumed thread that did not load (Retry bar)
///   -AgentsDemoHermes       the chat is on Hermes instead of Atlas
///   -AgentsDemoDrawer       open on the history drawer
///   -AgentsDemoDrawerEmpty  ...with no chats in it
///   -AgentsDemoDrawerError  ...whose load failed
///   -AgentsDemoToken        the token prompt, as a new install sees it
enum DemoMode {

    static var isActive: Bool { has("-AgentsDemo") }

    static var showsTokenEntry: Bool { isActive && has("-AgentsDemoToken") }
    static var opensDrawer: Bool {
        isActive && (has("-AgentsDemoDrawer") || has("-AgentsDemoDrawerEmpty") || has("-AgentsDemoDrawerError"))
    }
    static var expandsTools: Bool { isActive && !has("-AgentsDemoBusy") }
    static var resumeFailed: Bool { isActive && has("-AgentsDemoFailed") }

    private static func has(_ flag: String) -> Bool {
        #if DEBUG
            return ProcessInfo.processInfo.arguments.contains(flag)
        #else
            return false
        #endif
    }

    // MARK: - the chat

    /// Which agent the shell opens on. nil outside demo mode, which leaves the
    /// shell's own `.fallback` in charge.
    static var initialChoice: AgentChoice? {
        guard isActive else { return nil }
        return has("-AgentsDemoHermes") ? AgentChoice.all[1] : nil
    }

    /// Fills a freshly built chat model. A no-op outside demo mode.
    @MainActor
    static func seed(_ model: ChatModel) {
        guard isActive, !has("-AgentsDemoEmpty") else { return }
        if resumeFailed {
            // What `ClaudeView.loadResume` leaves behind when the fetch throws.
            model.bubbles = [Bubble(kind: .error, text: resumeError)]
        } else if has("-AgentsDemoBusy") {
            model.bubbles = busyBubbles
            model.busy = true
            model.startedAt = Date().addingTimeInterval(-75)
        } else if has("-AgentsDemoEnds") {
            model.bubbles = endingBubbles
        } else {
            model.bubbles = conversation
        }
    }

    static let resumeError = "Couldn't load this conversation: The hub answered 502: bad gateway"

    private static let conversation: [Bubble] = [
        Bubble(kind: .you, text: "Why is the Caddy reload on atlas failing? It worked yesterday."),
        Bubble(
            kind: .tool, text: "journalctl -u caddy --since today", toolName: "Bash",
            toolResult: """
                Sep 21 08:14:02 atlas caddy[1187]: {"level":"error","msg":"adapting config"}
                Sep 21 08:14:02 atlas caddy[1187]: Caddyfile:41 - unrecognized directive: tls_internal
                Sep 21 08:14:02 atlas systemd[1]: caddy.service: Reload failed.
                """),
        Bubble(
            kind: .tool, text: "/opt/stack/caddy/Caddyfile", toolName: "Read",
            toolResult: "(247 lines)"),
        Bubble(
            kind: .assistant,
            text: """
                The reload is failing on **line 41** of the live Caddyfile, not on anything that changed in git. Someone added `tls_internal` as a bare directive, but it only exists as an option inside a `tls` block:

                ```caddy
                example.com {
                    tls internal
                    reverse_proxy app
                }
                ```

                Caddy validates the whole file before swapping it in, so the running config is still yesterday's and nothing is down yet - but the next restart will not come back up. Want me to fix line 41 and run `caddy validate` before reloading?
                """),
    ]

    private static let endingBubbles: [Bubble] = [
        Bubble(kind: .you, text: "Summarise the last week of backup logs."),
        {
            var b = Bubble(kind: .assistant, text: "Seven nightly runs, six clean. The Tuesday run on hermes skipped `/data/media` because the mount was")
            b.stopped = true
            return b
        }(),
        Bubble(kind: .you, text: "Just tell me which night failed and why."),
        {
            var b = Bubble(
                kind: .assistant,
                text:
                    "Tuesday 02:00 on hermes. The NFS mount from atlas timed out after 90s, so restic backed up an empty directory and reported success, which is why nothing alerted. The"
            )
            b.incomplete = true
            return b
        }(),
        Bubble(kind: .error, text: "The hub is busy with other turns. Try again when one finishes."),
    ]

    private static let busyBubbles: [Bubble] = [
        Bubble(kind: .you, text: "Rebuild the audio-index container on atlas and tell me when it's healthy."),
        Bubble(kind: .tool, text: "docker compose -f /opt/stack/audio/compose.yml build", toolName: "Bash"),
        Bubble(kind: .assistant, text: "Building now. The image pulls a fresh Python base, so the first step takes a minute or two."),
    ]

    // MARK: - the drawer

    enum DrawerOutcome { case list, empty, failed }

    static var drawerOutcome: DrawerOutcome {
        if has("-AgentsDemoDrawerEmpty") { return .empty }
        if has("-AgentsDemoDrawerError") { return .failed }
        return .list
    }

    static let drawerError = HubError.unreachable

    /// Newest first, as the hub sends them. Times are relative to launch so
    /// the "5 min. ago" labels stay believable in any screenshot.
    static var conversations: [Conversation] {
        let now = Date().timeIntervalSince1970 * 1000
        func ago(_ minutes: Double) -> Double { now - minutes * 60_000 }
        return [
            Conversation(
                id: "c1", source: "claude", node: "atlas",
                title: "Why is the Caddy reload on atlas failing?", updatedAt: ago(4), count: nil),
            Conversation(
                id: "h1", source: "hermes", node: "hermes",
                title: "Summarise the last week of backup logs", updatedAt: ago(38), count: 12),
            Conversation(
                id: "k1", source: "hermes", node: "calypso",
                title: "Paper-trade the calypso strategy against last Friday's open and compare fills", updatedAt: ago(190), count: 31),
            Conversation(
                id: "c2", source: "claude", node: "atlas",
                title: "Rebuild the audio-index container", updatedAt: ago(60 * 26), count: nil),
            Conversation(
                id: "h2", source: "hermes", node: "hermes",
                title: "Draft the rack hardening checklist", updatedAt: ago(60 * 24 * 3), count: 7),
            Conversation(
                id: "c3", source: "claude", node: "atlas",
                title: "Tailscale ACL for the iris build node", updatedAt: ago(60 * 24 * 6), count: nil),
        ]
    }

    static let conversationErrors: [ConversationError] = [
        ConversationError(source: "hermes", node: "iris", error: "connect ECONNREFUSED", code: nil)
    ]
}
