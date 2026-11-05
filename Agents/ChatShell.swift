import SwiftUI

/// The app's root: a chat, a top bar over it, and the history drawer.
///
/// NO `NavigationStack` ANYWHERE IN THIS APP NOW. Nothing pushes - tapping a
/// history row swaps `target`, it does not navigate - so a stack would buy a
/// navigation bar this view already replaces and a back button pointing at
/// nothing. That is also why `ClaudeView` loses its `.navigationTitle` and its
/// toolbar in Task 8: with no stack above them those modifiers are inert, and
/// an inert `.navigationTitle` is worse than none because it reads as the title
/// on screen.
struct ChatShell: View {
    /// EVERY LAUNCH OPENS AN EMPTY ATLAS CHAT - not the last thread, not the
    /// most recent Atlas thread. One predictable starting state rather than one
    /// that depends on what you did last week; the previous thread is one
    /// hamburger tap away.
    @State private var target = ChatTarget.fresh(DemoMode.initialChoice ?? .fallback)
    @State private var drawer = DrawerState()

    /// How the pencil reaches the turn running inside the chat it is about to
    /// replace. See `ChatHandle` - the chat registers itself on appear, and
    /// this is the only thing the shell can say to it that is not a new target.
    @State private var handle = ChatHandle()

    /// The voice chat, and whether a question is with it - see `chat` and
    /// `showVoiceChat`. Observed, not copied, like `VoiceOverlay`'s session.
    private let atlasVoice = AtlasVoice.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Leaves a strip of the chat visible at the right, so the drawer reads as
    /// a panel over the app rather than as a different screen.
    private let panelWidth: CGFloat = 300

    /// How far in from the leading edge a drag has to START to mean "open the
    /// drawer" rather than "scroll the chat". A filter on the touch, not the
    /// width of any view - see `edgeOpenDrag`.
    private let edgeWidth: CGFloat = 20

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                // No Divider: `.deckBar(.top)` draws the bar's own 3px edge.
                topBar
                // THE WHOLE MECHANISM. A new `target` is a different `.id`, so
                // SwiftUI tears this view down and builds a new one with a
                // fresh `ChatModel` - which is what makes "switch agent" and
                // "open a thread" the same one line of code. The voice chat is
                // the one exception: its model already exists, see `chat`.
                //
                // An in-flight turn is NOT killed by this. hub/turns.js made
                // the turn and the response two different objects precisely so
                // a dropped subscriber does not stop the run; the answer lands
                // in the turn's buffer and the thread is in the drawer.
                chat
                    .id(target)
                    .overlay(alignment: .bottom) { VoiceOverlay() }
                    // Emails Claude proposed, waiting for Send / Cancel.
                    .overlay(alignment: .top) { MailApprovalStack() }
            }
            // THE DRAG THAT OPENS THE DRAWER RIDES ON THE CHAT ITSELF, and the
            // leading edge is a filter inside it rather than a view of its own.
            // See `edgeOpenDrag` - a separate strip was built, measured, and
            // deleted.
            .simultaneousGesture(edgeOpenDrag)

            scrim
            panel
        }
        .deckGround()
        .onAppear {
            if DemoMode.opensDrawer { drawer.open() }
            // A cold launch straight into the foreground mid-answer - opened
            // from the Live Activity, say. Neither `onChange` below fires for
            // the value a view starts with, so without this the answer runs
            // on off screen behind an empty Atlas chat.
            if atlasVoice.answering { showVoiceChat() }
        }
        // A question from the Action Button, the control or the wake word,
        // while the app is on screen: switch to the voice chat to show it
        // being answered. NOT when the app is in the background - there is
        // nothing to show, and it would yank the screen on the next unlock.
        .onChange(of: atlasVoice.asked) { showVoiceChat() }
        // Unlocking the phone mid-answer lands on the answer. `answering`,
        // not a running `VoiceSession`: a composer-mic question is in the chat
        // already on screen, and switching away from it would hide it.
        // `target.isVoice` too: a voice chat left on screen while a question
        // from the lock screen started a new thread is showing the OLD model -
        // `@State` kept it - and unlocking moves it to the current one.
        // A HANDS-FREE CONVERSATION with the voice chat counts too: between
        // turns it is listening, not answering, and unlocking then should
        // still land on the thread being talked in.
        .onChange(of: scenePhase) {
            if atlasVoice.answering || target.isVoice || VoiceSession.shared.asking === atlasVoice { showVoiceChat() }
        }
    }

    // MARK: - the chat

    /// The chat for `target`. The voice chat's model already exists - see
    /// `AtlasVoice` - so it is handed in, not built. Falls back to a fresh
    /// Atlas chat if it is somehow not there, rather than showing nothing.
    @ViewBuilder private var chat: some View {
        if target.isVoice, let model = atlasVoice.model {
            ClaudeView(model: model, handle: handle)
        } else {
            ClaudeView(
                agent: target.agent, title: target.title,
                resume: target.resume, handle: handle)
        }
    }

    /// No cancel of the chat being left, as with the drawer: its turn keeps
    /// running into its own thread. Only the pencil cancels.
    ///
    /// The composer mic never lands here: it asks a `ChatModelTurn` on the
    /// model already on screen, never `AtlasVoice`, so neither `asked` nor
    /// `answering` moves. `isShowing` keeps a second question into the voice
    /// chat on screen from rebuilding it - while a question that got a NEW
    /// model, the thread having gone quiet for ten minutes, still switches,
    /// because the old model is the one showing.
    ///
    /// THE DRAWER CLOSES whenever there is an answer to see - a switch, or a
    /// question into the voice chat already under it - or the answer is
    /// written behind the panel. Not on a bare unlock with nothing new: that
    /// would shut a drawer the user left open on purpose.
    private func showVoiceChat() {
        guard scenePhase == .active, let model = atlasVoice.model else { return }
        if !handle.isShowing(model) {
            target = .voice()
        } else if !atlasVoice.answering {
            return
        }
        withAnimation(.snappy) { drawer.close() }
    }

    // MARK: - the bar

    private var topBar: some View {
        HStack(spacing: Theme.sp3) {
            Button {
                withAnimation(.snappy) { drawer.open() }
            } label: {
                Image(systemName: "line.3.horizontal")
            }
            .buttonStyle(DeckIconButtonStyle())
            .accessibilityLabel("Chats")

            Spacer()
            agentMenu
            Spacer()

            Button {
                // THE ONLY GESTURE IN THE APP THAT CANCELS A TURN, and the one
                // that must. A dropped subscriber may never kill a run - that
                // is what `hub/turns.js` separates the turn from the socket for,
                // and it is why a locked phone comes back to a finished answer -
                // but pressing New is not a dropped subscriber. It is the user
                // saying they are done with this one, and a turn nobody will
                // ever read still holds one of the hub's three slots until it
                // times out. Tap here three times during long answers without
                // this line and the next send returns "The hub is busy with
                // other turns" with nothing visibly running to explain it.
                //
                // BEFORE the target changes, necessarily: afterwards the handle
                // points at the new chat and the old model is unreachable.
                // The voice session too, ONLY WHEN IT IS ASKING THIS CHAT: the
                // composer mic's question into the model on screen, or a
                // question into the voice chat while that is on screen. A
                // session asking any other chat - the voice chat off screen,
                // a chat left through the drawer - is not the one being left,
                // and its answer goes on being read.
                let voice = VoiceSession.shared
                if handle.isAsked(by: voice.asking) || (target.isVoice && voice.asking === atlasVoice) {
                    voice.cancel()
                }
                handle.cancelLiveTurn()
                // On the voice chat, the pencil is done with its THREAD too,
                // so the next question does not continue it for ten minutes.
                // AFTER the cancels: `AtlasVoice.cancel` reaches the turn
                // through the model this drops.
                if target.isVoice { atlasVoice.forget() }
                // A FRESH TARGET EVERY TIME, even on the same agent -
                // ChatTarget.fresh mints a new generation, so this rebuilds
                // rather than comparing equal and doing nothing.
                target = .fresh(target.choice)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(DeckIconButtonStyle())
            .accessibilityLabel("New chat")
        }
        .padding(.horizontal, Theme.sp4)
        .padding(.vertical, Theme.sp3)
        .deckBar(.top)
    }

    private var agentMenu: some View {
        Menu {
            // A `Picker` would be the obvious control and cannot show two lines
            // per row. The machine and what runs on it are different facts and
            // both have to be readable - see AgentChoice.
            ForEach(AgentChoice.all) { choice in
                Button {
                    // SWITCHING AGENT STARTS A FRESH CHAT, with no
                    // confirmation. atlas and hermes keep separate session
                    // stores, so there is no id that means the same thing to
                    // both and the current thread cannot follow you across.
                    // It is untouched and in the drawer a second later.
                    // The guard protects an in-progress FRESH chat from a
                    // pointless rebuild. A RESUMED thread is always worth
                    // leaving: the label already reads "Hermes", so choosing
                    // Hermes while reading an old Hermes thread can only mean
                    // "get me out of here" - and a bare `choice != target.choice`
                    // makes that a silent no-op, a dead control at the one
                    // moment reaching for it is most deliberate. It is also
                    // inconsistent without this: `forConversation` mints an
                    // unequal choice for an unknown node, so the same gesture
                    // would behave differently depending on whether the
                    // thread's node happens to be in `all`. The voice chat is
                    // the same case: it reads "Atlas" too, and choosing Atlas
                    // there means a fresh Atlas chat, not "stay".
                    guard target.resume != nil || target.isVoice || choice != target.choice else { return }
                    // NO `handle.cancelLiveTurn()` HERE, unlike the pencil, and
                    // that asymmetry is a decision rather than an oversight.
                    // The pencil says "I am done with this answer"; reaching for
                    // another machine does not, and the turn you left keeps
                    // running into a thread the drawer can open again. Arguable
                    // either way - revisit it on the strength of the device
                    // walkthrough, not from the armchair.
                    target = .fresh(choice)
                } label: {
                    // TWO BARE `Text`s, NOT A `VStack`. A `Menu` button's label
                    // maps a SECOND BARE `Text` to the row's subtitle, drawn
                    // grey under the title - and wrapping the pair in any
                    // container defeats that mapping entirely. The row then
                    // collapses to the first string with no warning and nothing
                    // visibly broken: measured, a `VStack` gives a 52.76pt row
                    // reading only "Hermes", and `choice.kind` is absent from
                    // the accessibility tree too, so VoiceOver loses it as well.
                    // Bare, the row is 75.38pt and reads "Hermes / Hermes
                    // agent". Re-adding the `VStack` is the obvious tidy-up and
                    // it silently makes this picker strictly WORSE than the
                    // `Picker` the comment above argues against, erasing the one
                    // signal that separates Hermes from Calypso.
                    Text(choice.machine)
                    Text(choice.kind)
                }
                // A Menu row's subtitle is VISUAL ONLY - measured, `choice.kind`
                // never enters the accessibility tree in either form, so
                // VoiceOver reads "Hermes" and "Calypso" as indistinguishable
                // without this.
                .accessibilityLabel("\(choice.machine), \(choice.kind)")
            }
        } label: {
            // The agent's swatch BESIDE its name, never instead of it - the
            // same pairing every agent message carries, so the colour in the
            // bar is the colour down the edge of the answers below it.
            HStack(spacing: Theme.sp2) {
                AgentSwatch(colour: Theme.agentColour(node: target.choice.node))
                Text(target.choice.machine)
                    .font(Deck.sans(16, .bold, relativeTo: .headline))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
        }
        // A Deck button, so the picker presses into its shadow like every
        // other control in the bar. The rows it opens are the system menu's
        // and stay that way - see the comment on the rows above.
        .menuStyle(.button)
        .buttonStyle(.deck)
        .accessibilityLabel("Agent: \(target.choice.machine)")
    }

    // MARK: - the drawer

    private var scrim: some View {
        Theme.scrim
            .opacity(drawer.scrimOpacity(width: panelWidth))
            .ignoresSafeArea()
            // NOT `drawer.isOpen`. A closed drawer's scrim that still takes hit
            // testing silently swallows every tap meant for the chat - the
            // composer just stops responding. See DrawerState.isInteractive.
            .allowsHitTesting(drawer.isInteractive)
            .onTapGesture { withAnimation(.snappy) { drawer.close() } }
            .accessibilityHidden(!drawer.isInteractive)
    }

    /// KEEP THIS AT A FIXED POSITION IN THE ZSTACK, unconditional and
    /// un-`id`'d. `HistoryDrawer` holds its loaded conversations in `@State`,
    /// and that storage survives `ChatShell` re-rendering only because the
    /// drawer stays the same view type at the same structural position.
    /// Wrapping it in an `if`, or moving it inside the `.id(target)` scope,
    /// gives it a new identity every time the target changes - so every switch
    /// of agent silently throws the list away and refetches, showing a spinner
    /// where the history was. `.id(target)` is scoped to `ClaudeView` alone on
    /// purpose.
    private var panel: some View {
        HistoryDrawer(isOpen: drawer.isOpen) { conv in
            // DELIBERATELY NO CANCEL. Going off to read another thread while an
            // answer is still being written, then coming back to it, is the
            // exact case the hub's detachable turns exist for - the run
            // continues, the answer lands in its buffer, and the thread is one
            // row away in this same list. Only the pencil cancels.
            target = .resuming(conv)
            withAnimation(.snappy) { drawer.close() }
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity)
        // The rail, as Deck's sidebar is, with the 3px structural edge on the
        // side that faces the chat. NO HARD SHADOW past that edge: the closed
        // panel sits at exactly x = -panelWidth, so anything drawn beyond its
        // frame would peek into the chat's leading 5pt while shut.
        .overlay(alignment: .trailing) {
            Rectangle().fill(Deck.line)
                .frame(width: Deck.borderWidthLarge)
                .ignoresSafeArea()
        }
        .background(Deck.rail)
        .offset(x: drawer.offset(width: panelWidth))
        .allowsHitTesting(drawer.isInteractive)
        // VoiceOver reads a ZStack layer whether or not it is on screen. Without
        // this, a closed drawer's whole conversation list is still in the rotor,
        // sitting between the agent picker and the composer.
        .accessibilityHidden(!drawer.isInteractive)
        .ignoresSafeArea(edges: .bottom)
        // CLOSING ONLY, AND CONSTRAINED WHILE IT CLOSES. Two separate points,
        // both load-bearing.
        //
        // CLOSING ONLY: this gesture can never OPEN the drawer, and that is not
        // a bug in it. When the drawer is shut the panel sits at x = -300, off
        // screen, with `allowsHitTesting(false)` - two independent reasons a
        // finger can never land on it. The opening half therefore lives in
        // `edgeOpenDrag`, on the chat, which is always live. Attaching both
        // here would
        // silently ship an app whose drawer only opens from the toolbar button,
        // with the drag code present and unreachable.
        //
        // CONSTRAINED: `minimumDistance: 20` and the horizontal-intent guard
        // are there because an unfiltered DragGesture here fights the List
        // inside the panel. At the default `minimumDistance: 10` a vertical or
        // diagonal drag the ancestor claims calls `track()` with a near-zero
        // width: the panel jitters, `isInteractive` sticks true mid-scroll, and
        // a pull-to-refresh is interrupted. `.gesture` gives the parent LOWER
        // priority than child gestures so the List usually wins - "usually" is
        // not a guarantee worth shipping.
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { g in
                    // Horizontal intent only. A drag steeper than 45 degrees
                    // is a scroll, and belongs to the List.
                    guard abs(g.translation.width) > abs(g.translation.height) else { return }
                    drawer.track(g.translation.width)
                }
                .onEnded { g in
                    // Only the open->closed direction, because this gesture is
                    // only reachable while the drawer is open. Past a third of
                    // the panel, or thrown hard enough leftward, it closes;
                    // otherwise it springs back open.
                    let travelled = g.translation.width
                    let flung = g.predictedEndTranslation.width < -panelWidth / 2
                    withAnimation(.snappy) {
                        if travelled < -panelWidth / 3 || flung { drawer.close() } else { drawer.open() }
                    }
                }
        )
    }

    /// THE ONLY THING THAT CAN OPEN THE DRAWER BY DRAGGING - and it is a
    /// gesture on the chat, NOT a view of its own.
    ///
    /// DO NOT REBUILD THIS AS A DEDICATED EDGE STRIP. That is the obvious
    /// shape, it was built, and it was measured under XCUITest in a scratch
    /// app: a narrow `Color.clear` layer above the chat in the ZStack with
    /// `.contentShape(.rect)` is hit-test-OPAQUE, so it consumes the touch
    /// outright and the chat underneath never sees it. At x = 8 a vertical drag
    /// scrolled the transcript not at all - offset 0, against -411 for the
    /// identical drag at x = 200 - and a tap never arrived either (tap count 0
    /// at x = 8, 1 at x = 200). THE SYMPTOM TO RECOGNISE is the leading 20pt of
    /// the chat not scrolling and not dismissing the keyboard, which quietly
    /// costs one of the two escapes ClaudeView documents.
    ///
    /// `.simultaneousGesture` DOES NOT RESCUE THAT LAYOUT - measured
    /// indistinguishable from `.gesture`, offset 0 and no tap through under
    /// both. It relaxes composition against a view's own ancestors and
    /// descendants, and the chat is neither: it is a ZStack SIBLING underneath.
    /// A gesture that never competes for the touch cannot be made to share it,
    /// so no modifier on a separate strip can work.
    ///
    /// Hence this shape. The gesture belongs to the chat, attached
    /// simultaneously so the `ScrollView` keeps its own, and the edge is a
    /// filter on `startLocation` rather than a set of bounds. Measured the same
    /// way: scrolls at x = 8 (offset -414), taps through (count 1), still opens
    /// on a rightward drag, still leaves the panel alone on a diagonal one.
    ///
    /// NOTHING GATES THIS ON `drawer.isOpen`. With the drawer open the scrim
    /// sits above the chat and takes the touches, which is the job the deleted
    /// strip's `allowsHitTesting(!drawer.isOpen)` used to do.
    private var edgeOpenDrag: some Gesture {
        DragGesture()
            .onChanged { g in
                // WHERE THE FINGER STARTED, not where it is now - the whole
                // point of a start-location filter is that it keeps deciding
                // the same way once the drag has left the edge.
                guard g.startLocation.x < edgeWidth else { return }
                // Rightward AND horizontal intent, the same test the panel's
                // own drag uses. Rightward alone is not enough now that the
                // ScrollView sees this touch too: a diagonal scroll carries a
                // positive width and would drag the panel partway open under
                // the finger while the transcript scrolls.
                guard g.translation.width > 0,
                    abs(g.translation.width) > abs(g.translation.height)
                else { return }
                drawer.track(g.translation.width)
            }
            .onEnded { g in
                // Re-checked, because `onEnded` fires for every drag on the
                // chat - including the ones `onChanged` declined to track.
                // Without this a scroll that ends anywhere would run the
                // open/close decision below on a drag that never moved the
                // panel.
                guard g.startLocation.x < edgeWidth else { return }
                let flung = g.predictedEndTranslation.width > panelWidth / 2
                withAnimation(.snappy) {
                    if g.translation.width > panelWidth / 3 || flung { drawer.open() } else { drawer.close() }
                }
            }
    }
}

/// The `VoiceBar`, whenever a session is running, whichever trigger started it.
///
/// A VIEW OF ITS OWN SO THAT ONLY IT READS `phase`. Read in `ChatShell`, every
/// partial transcript re-ran the shell's body - and `ClaudeView.init`, with the
/// throwaway model that builds - and the animation below, on the chat itself,
/// would crossfade the pencil's `.id(target)` rebuild. Observed, not copied,
/// the same as `HubToken.shared` in RootView.
private struct VoiceOverlay: View {
    private let voice = VoiceSession.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            if !voice.phase.isIdle {
                VoiceBar(phase: voice.phase, press: { voice.press() }, cancel: { voice.cancel() })
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.snappy, value: voice.phase.isIdle)
    }
}
