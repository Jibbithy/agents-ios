import SwiftUI

/// The conversation list, as a panel over the chat rather than as a screen of
/// its own - every thread across Claude (atlas) and Hermes (hermes/calypso),
/// newest first.
///
/// A LIST AND NOTHING ELSE. Three things a full-screen conversation list would
/// carry are deliberately absent, and each is absent for its own reason:
///
///   - NO `NavigationStack` - the shell owns navigation, and there is none:
///     tapping a row swaps the shell's `ChatTarget` rather than pushing.
///   - NO pencil - that button is in the shell's top bar, where it is reachable
///     without opening this panel at all.
///   - NO filter chips - the panel is narrow, and every row already carries a
///     machine badge. All conversations, newest first, which is what a history
///     list is for.
///
/// What it does carry, because a panel needs these no less than a screen did:
/// the partial-failure section, `.refreshable`, and the `.key`-based `ForEach`
/// identity.
struct HistoryDrawer: View {
    /// Whether the drawer is currently open. Input only - this view never
    /// changes it and knows nothing about scrims, offsets or gestures.
    ///
    /// FIRST SO THAT `onSelect` CAN BE A TRAILING CLOSURE at the shell's call
    /// site. Swift's memberwise init takes these in declaration order, so
    /// flipping them later is a source break at every construction.
    let isOpen: Bool

    /// Called with the thread that was tapped. The shell turns it into a
    /// `ChatTarget` and closes the drawer; this view does not know either of
    /// those things happen.
    let onSelect: (Conversation) -> Void

    @State private var conversations: [Conversation] = []
    @State private var errors: [ConversationError] = []
    @State private var loadError: HubError?
    @State private var loading = true
    @State private var changingToken = false
    @State private var settingMailKey = false
    @State private var settingVoice = false
    private let heyAtlas = HeyAtlas.shared

    var body: some View {
        VStack(spacing: 0) {
            Text("Chats")
                .font(Deck.title)
                .textCase(.uppercase)
                .foregroundStyle(Deck.ink)
                // Reachable by the VoiceOver heading rotor. It looks like a
                // heading and is the only landmark in the panel, but a plain
                // `Text` carries no trait to say so.
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.sp4)
                .padding(.vertical, Theme.sp3)
                // The panel's head rule: the 2px edge Deck puts above a table,
                // here the one the conversation list hangs from.
                .overlay(alignment: .bottom) { DeckRule() }

            Group {
                if loading {
                    ProgressView {
                        Text("Loading…").deckLabel()
                    }
                    .tint(Deck.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if conversations.isEmpty && errors.isEmpty {
                    // Both states in the Deck box they mean: a crit alert for
                    // a load that failed, the dashed "nothing here yet" box for
                    // an honest empty list - so the two cannot be mistaken for
                    // each other even at a glance, in greyscale.
                    Group {
                        if let loadError {
                            DeckAlert(
                                .crit, title: "Can't load chats",
                                message: loadError.localizedDescription)
                        } else {
                            DeckEmpty(
                                label: "History",
                                title: "No chats yet",
                                message: "Start one and it shows up here.")
                        }
                    }
                    .padding(Theme.sp4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    list
                }
            }

            themeFooter
        }
        // KEYED ON `isOpen`, AND A BARE `.task` HERE WOULD BE A SILENT BUG.
        // This view is an always-present layer in the shell's `ZStack` that
        // slides in on `.offset`; it is never added to or removed from the
        // hierarchy. `.task` is tied to a view's LIFETIME in the hierarchy, not
        // to its visibility or its position, so an unkeyed one fires once when
        // the stack is built and never again - exactly the `startedInitialLoad`
        // behaviour this was meant to replace, except invisible, with a thread
        // started two minutes ago missing until the app is relaunched. Keying
        // on `isOpen` is what makes "reload each time you open it" real.
        //
        // IT ALSO BUYS THE ONLY WAY OUT OF A FAILED FIRST LOAD, which is less
        // obvious: that case leaves the full-screen `ContentUnavailableView`,
        // and `.refreshable` lives on the `List` below, so there is nothing on
        // screen to pull. Without the key, re-opening the drawer would not
        // retry either and relaunching the app would be the only recourse.
        .task(id: isOpen) { if isOpen { await load() } }
    }

    /// Auto / Cream / Dark, pinned under the list. This app has no settings
    /// screen and its top bar is already full, so the theme sits where the web
    /// sidebar keeps its own controls: at the foot of the rail. Outside the
    /// loading/empty/list switch above, so a hub that is down cannot hide it.
    ///
    /// "Change token" lives here too, for the same reason: no settings screen.
    /// A 401 already sends the app back to the token screen by itself (see
    /// HubToken); this is the deliberate way, for a token rotated before the
    /// phone has noticed. It opens the token screen as a SHEET and forgets
    /// nothing until a new token is proved, so tapping it by mistake is free.
    private var themeFooter: some View {
        VStack(alignment: .leading, spacing: Theme.sp2) {
            // OFF BY DEFAULT. On, it keeps the screen awake and the mic open
            // while the app is showing - right for a phone on a car mount,
            // wrong for one in a pocket.
            //
            // SAYS WHY WHEN IT CANNOT LISTEN - no model in this build (then
            // off and greyed), or no mic allowed yet: a switch that is on and
            // never hears a thing reads as a broken wake word.
            Toggle(
                isOn: Binding(
                    get: { heyAtlas.enabled && HeyAtlas.installed },
                    set: { heyAtlas.enabled = $0 })
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listen for “Hey Atlas”").font(Deck.body).foregroundStyle(Deck.ink)
                    if let note = heyAtlas.note {
                        Text(note).font(Deck.small).foregroundStyle(Deck.muted)
                    }
                }
            }
            .tint(Deck.accentInk)
            .disabled(!HeyAtlas.installed)
            .padding(.bottom, Theme.sp1)
            // Hands-free on/off and the end phrases. No settings screen.
            Button {
                settingVoice = true
            } label: {
                Label("Voice chat", systemImage: "waveform")
            }
            .buttonStyle(DeckButtonStyle(.ghost, small: true))
            .padding(.bottom, Theme.sp1)
            Text("Theme").deckLabel()
            DeckThemePicker()
            Button {
                changingToken = true
            } label: {
                Label("Change token", systemImage: "key")
            }
            .buttonStyle(DeckButtonStyle(.ghost, small: true))
            .padding(.top, Theme.sp1)
            // Next to the token for the same reason: no settings screen.
            Button {
                settingMailKey = true
            } label: {
                Label("Mail approval key", systemImage: "envelope.badge.shield.half.filled")
            }
            .buttonStyle(DeckButtonStyle(.ghost, small: true))
        }
        .sheet(isPresented: $changingToken) {
            TokenEntryView(onClose: { changingToken = false })
        }
        .sheet(isPresented: $settingMailKey) {
            ApprovalKeyEntryView(onClose: { settingMailKey = false })
        }
        .sheet(isPresented: $settingVoice) {
            VoiceSettingsView(onClose: { settingVoice = false })
        }
        .padding(.horizontal, Theme.sp4)
        .padding(.vertical, Theme.sp3)
        // The shell lets the panel run under the home indicator (so the list
        // scrolls beneath it); the strip must not, or its bottom edge is cut.
        .safeAreaPadding(.bottom)
        .overlay(alignment: .top) { DeckRule() }
    }

    private var list: some View {
        List {
            // A down source still answers 200 with a partial list, so this
            // names the gap WITHOUT touching the rows below it: a `loadError`
            // here means a REFRESH failed while yesterday's rows are still on
            // screen, which is exactly when they must stay listed and tappable.
            //
            // ONE WARN ALERT, not a section of orange lines: the ◆ and the
            // amber edge say "partial" before a word is read, and the lines
            // inside are the same lines, in the same order, as before.
            if !errors.isEmpty || loadError != nil {
                DeckAlert(
                    .warn, title: "Some sources didn't answer",
                    message: partialLines.joined(separator: "\n")
                )
                // The rows' own 16pt gutter, so the box lines up with them.
                .padding(.horizontal, Theme.sp4)
                .padding(.vertical, Theme.sp3)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section {
                // Keyed on `.key` ("source/node/id"), not `.id`. Two Hermes
                // boxes mint ids from the same `api_<ms>_<rand>` scheme, so a
                // cross-node collision on the bare id is unlikely but not ruled
                // out - `.key` is the field `Conversation` defines to stay
                // unique across sources and nodes.
                ForEach(conversations, id: \.key) { conv in
                    Button {
                        onSelect(conv)
                    } label: {
                        HistoryRow(conv: conv, first: conv.key == conversations.first?.key)
                    }
                    .buttonStyle(.plain)
                    // Deck rows draw their own fill and hair; the List's
                    // insets, background and separators would double them.
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                // The table's closing edge.
                DeckTableEdgeRow()
            }
        }
        .listStyle(.plain)
        // Rows set their own 44pt floor (`deckRow`). The List's default
        // floor would otherwise pad the 2px closing rule into a 44pt row and
        // leave it floating a gap below the last conversation.
        .environment(\.defaultMinListRowHeight, 0)
        // The shell paints the panel `Deck.rail`; a `List` paints
        // `systemBackground` over it, which is neither cream nor soot. The
        // "Chats" header and the two empty states sit OUTSIDE the `List` and
        // stay rail-coloured, so without this the panel reads as two different
        // grounds stacked. Hiding the scroll background lets the panel's own
        // colour through, which is what every other surface in the app does.
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
    }

    /// The partial-failure lines, one per source that did not answer, then the
    /// refresh failure if there was one.
    private var partialLines: [String] {
        var lines = errors.map { "\($0.source)/\($0.node): \($0.error)" }
        if let loadError { lines.append("Refresh failed: \(loadError.localizedDescription)") }
        return lines
    }

    private func load() async {
        // THE SPINNER COMES BACK ONLY WHEN THERE IS NOTHING TO LOOK AT. Without
        // this, a retry after a failed or cancelled first load runs with
        // `loading` still false and an empty list, so the whole 20s of it
        // renders as the "Can't load chats" screen - a live retry that looks
        // exactly like a dead one.
        //
        // IT CANNOT FIRE DURING PULL-TO-REFRESH, which is the property that
        // makes it safe: `.refreshable` lives on the `List`, and the `List` is
        // only on screen when this condition is false. So a refresh still keeps
        // its own spinner and yesterday's rows rather than blanking them.
        if conversations.isEmpty && errors.isEmpty { loading = true }

        if DemoMode.isActive {
            switch DemoMode.drawerOutcome {
            case .list:
                conversations = DemoMode.conversations
                errors = DemoMode.conversationErrors
            case .empty:
                conversations = []
            case .failed:
                loadError = DemoMode.drawerError
            }
            loading = false
            return
        }

        do {
            let page = try await HubClient.shared.conversations()
            conversations = page.conversations
            errors = page.errors
            loadError = nil
        } catch {
            // `Task.isCancelled`, NOT `error is CancellationError`, and the
            // obvious-looking version is DEAD CODE: closing the drawer cancels
            // this task through `URLSession`, which throws `URLError(.cancelled)`,
            // and `HubClient.mapped` turns that into `.http(0, "cancelled")`.
            // It arrives here as a `HubError`, never as a `CancellationError`.
            //
            // The guard returns BEFORE `loading = false` on purpose. Falling
            // through would leave the drawer holding "The hub answered 0:
            // cancelled" - `HubError`'s own doc comment forbids `.http(0,)`
            // for a fault on this side of the wire, and this is that lie
            // exactly: we cancelled it, the hub never misbehaved.
            guard !Task.isCancelled else { return }
            loadError = (error as? HubError) ?? .http(0, error.localizedDescription)
        }
        loading = false
    }
}

/// One row: title, then the machine (its swatch and name), the agent kind,
/// the relative time, and the message count only when the hub sent one.
private struct HistoryRow: View {
    let conv: Conversation
    /// The first row hangs straight off the panel's head rule, so it takes no
    /// hair of its own above it.
    let first: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(conv.title)
                .font(Theme.rowTitle)
                .lineLimit(2)
                .foregroundStyle(Deck.ink)
            // One line when it fits, two when Dynamic Type makes it not - the
            // machine is the one fact that must never be truncated away.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.sp2) {
                    machine
                    when
                    Spacer(minLength: 0)
                    count
                }
                VStack(alignment: .leading, spacing: 4) {
                    machine
                    HStack(spacing: Theme.sp2) {
                        when
                        Spacer(minLength: 0)
                        count
                    }
                }
            }
        }
        .deckRow(separator: !first)
        .contentShape(.rect)
    }

    /// The machine's swatch and name, then the agent kind - the name always
    /// beside the colour, as everywhere else in the app.
    private var machine: some View {
        HStack(spacing: 6) {
            AgentSwatch(colour: Theme.agentColour(node: conv.node))
            Text(conv.node)
                .foregroundStyle(Deck.ink)
            Text(conv.source.capitalized)
                .foregroundStyle(Deck.muted)
        }
        .font(Theme.meta)
        .textCase(.uppercase)
        .lineLimit(1)
        .fixedSize()
    }

    private var when: some View {
        Text(conv.relativeTime ?? "unknown time")
            .font(Theme.meta)
            .textCase(.uppercase)
            .foregroundStyle(Deck.muted)
            .lineLimit(1)
            .fixedSize()
    }

    // `count` is null for Claude - a badge reading "0" would claim the hub
    // counted an empty thread when it never looked, so absence renders as no
    // badge, not a zero.
    @ViewBuilder private var count: some View {
        if let count = conv.count {
            // An HStack, not a `Label`: inside the List row a Label chose
            // its icon-only form and silently dropped the number.
            HStack(spacing: 4) {
                Image(systemName: "bubble.left")
                Text("\(count)")
            }
            .font(Theme.meta)
            .foregroundStyle(Deck.muted)
            .fixedSize()
            // The `Button` flattens this row into ONE VoiceOver
            // element, so without a label the count is read as a
            // bare number between the timestamp and "Button".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count) messages")
        }
    }
}

extension Conversation {
    /// nil when the hub reported nothing (`updatedAt == 0`), which renders as
    /// "unknown time" rather than the misleading "56 years ago" a raw
    /// epoch-zero date would produce through `RelativeDateTimeFormatter`.
    @MainActor
    fileprivate var relativeTime: String? {
        guard updatedAt > 0 else { return nil }
        return Self.relativeFormatter.localizedString(
            for: Date(timeIntervalSince1970: updatedAt / 1000),
            relativeTo: .now)
    }

    /// ONE FORMATTER FOR THE WHOLE LIST. Built per row body evaluation before
    /// this, which is per row per scroll pass, and a `DateFormatter` family
    /// class is not cheap to construct.
    ///
    /// `@MainActor` IS REQUIRED, NOT DECORATION: `RelativeDateTimeFormatter` is
    /// not `Sendable`, so under Swift 6 a bare `static let` of one is a
    /// compile error rather than a warning. Pinning it to the main actor is
    /// the honest fix because a `View` body is the only thing that reads it and
    /// bodies are main-actor isolated already - which is also why
    /// `relativeTime` above has to inherit the isolation.
    @MainActor
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
