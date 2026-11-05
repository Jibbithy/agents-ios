import PhotosUI
import SwiftUI

struct Bubble: Identifiable {
    enum Kind { case you, assistant, tool, error }
    let id = UUID()
    var kind: Kind
    var text: String
    var toolName: String = ""
    var toolResult: String = ""
    var incomplete = false
    /// The user pressed Stop on this answer.
    ///
    /// SEPARATE FROM `incomplete`, which means "the connection dropped", and
    /// the two must not be collapsed into one flag even though they describe
    /// the same truncated text. `incomplete` renders as an orange warning
    /// because something went wrong; a stop is the user getting what they
    /// asked for, and telling them their connection failed when they pressed
    /// the button themselves is how an app teaches people to distrust its
    /// error messages.
    var stopped = false
}

/// A chat with ONE agent, either fresh or resuming a conversation clicked in
/// history. `ClaudeModel` used to be Claude-only and carried its own
/// `conversation` id; now the model itself picks which hub route it talks to,
/// so a single type serves both the Claude tab and any Hermes conversation
/// Task 4's list opens.
@Observable
@MainActor
final class ChatModel {
    let agent: Agent
    /// What the composer's placeholder reads - "Ask Atlas" for a fresh chat,
    /// "Ask <the thread's title>" when resuming one. That placeholder is now
    /// the ONLY thing this feeds: the shell's top bar shows the agent picker
    /// rather than a title, and this view has no chrome of its own left.
    ///
    /// LET, NOT VAR, and it used to be the other way round for a reason that
    /// has since gone. The old "New" button reset this model IN PLACE, so the
    /// title had to be droppable or the placeholder would keep naming a thread
    /// the next turn was no longer going into. Nothing resets in place any
    /// more: a new chat, a resumed thread and a switched agent are all a new
    /// `ChatTarget`, and the shell's `.id(target)` builds a whole new
    /// `ChatModel` for each. One title per model, fixed at init, is therefore
    /// the accurate shape - and a `let` is what stops a future in-place reset
    /// being written without noticing that nothing rebuilds around it.
    let title: String
    var bubbles: [Bubble] = []
    var draft = ""
    /// Photos waiting to go with the next turn. Claude only: Hermes runs on
    /// other nodes and cannot read atlas's files.
    let tray = PhotoTray()
    var canAttach: Bool { agent == .claude }
    /// True while the tray uploads, before the turn itself starts.
    var uploading = false
    /// Injected so a test or demo never touches the hub. `@MainActor` to match
    /// `PhotoTray.uploadAll`, which calls it from the main actor.
    var uploadPhoto: @MainActor (String, Data) async throws -> String = { name, data in
        try await HubClient.shared.upload(dir: PhotoMessage.inbox, name: name, data: data)
    }
    var busy = false
    /// True while a turn is running but nothing is watching it - the app came
    /// back from the background and is re-attaching. Distinct from `busy`
    /// because the composer says something different in each state, and a user
    /// who has just unlocked their phone deserves to know which one they are
    /// looking at.
    var reconnecting = false

    /// When the turn in flight started, or nil if none is. Drives the elapsed
    /// count in `ThinkingRow`, and is the ONE source of "is there a turn to
    /// draw an indicator for" together with `busy` - a second bool would be a
    /// second thing to forget to clear.
    var startedAt: Date?

    /// The user stopped this turn on purpose. Latched for the length of one
    /// turn and cleared when the next one starts.
    ///
    /// WHY A FLAG AND NOT JUST `Task.isCancelled`. By the time `run` unwinds,
    /// what it can observe is a stream that ended - which is exactly what a
    /// dropped socket looks like, and that path marks the answer "connection
    /// dropped" and retries for five minutes. Only this model knows the
    /// difference between a turn that failed and a turn that was ended, and
    /// only because it was told.
    ///
    /// Readable outside because `ChatModelTurn` reports a stop from it: a Stop
    /// during a tool run has no reply bubble to mark.
    private(set) var stopped = false

    /// How the NEXT turn attaches to a thread, if at all. One `Attach` value
    /// rather than separate `conversation`/`sessionId` properties - mirroring
    /// `SSEStream.send`'s own parameter - so this model cannot drift into
    /// holding both a live `conversation` id and a stale `sessionId` at once
    /// the way two Optionals could after a resume. `run` is the only place
    /// that advances it, via `Agent.attach(afterConversationEvent:)`.
    private var attach: Attach = .none

    /// The id of the turn currently in flight, if any - what `attach` and
    /// `cancel` address. Held separately from `attach` because that property
    /// describes the NEXT turn's thread and this one describes THIS turn's
    /// process; conflating them is how a cancel reaches the wrong turn.
    private var liveTurnId: String?

    /// The thread this chat is in, once the hub has said - the id off the
    /// `conversation` event. Unlike `liveTurnId` it OUTLIVES the turn, because
    /// that is what `AtlasVoice` saves to continue the thread ten minutes on.
    private(set) var threadId: String?

    /// When the last turn in this chat ended, however it ended and however it
    /// was asked. `AtlasVoice` reads it as "the voice chat was used": typing or
    /// the composer mic there is use too, and neither goes through it to save
    /// the thread. Ignored by observation - no view draws it.
    @ObservationIgnored private(set) var lastTurnEnded: Date?

    /// Called with each tool's name as a turn runs it. The voice session's
    /// "Running Bash…" line; nil for a typed chat.
    @ObservationIgnored var onTool: (@MainActor @Sendable (String) -> Void)?

    /// Called with `threadId` the moment the hub names it, at the
    /// `conversation` event. `AtlasVoice` saves the thread then, not only when
    /// the turn ends - see `AtlasVoice.ask`. nil for every other chat.
    @ObservationIgnored var onThread: (@MainActor @Sendable (String) -> Void)?

    private var turn: Task<Void, Never>?
    /// tool_use id -> index in `bubbles`, so a tool_result lands on its own row
    /// rather than becoming a bubble of its own.
    private var toolRows: [String: Int] = [:]

    /// How this chat reaches the hub: `.live` everywhere but in tests, which
    /// hand in streams they control - the only way `run` can be driven
    /// through a dead socket, a backoff and a re-attach without a hub.
    @ObservationIgnored private let streams: Streams

    /// ONE TURN'S STREAM STATE, as properties rather than locals in `run`,
    /// because a turn is now read by a SERIES of reader tasks - one per
    /// socket, see `consume` - and each has to pick up exactly where the last
    /// left off. `replyRow` is the bubble the answer is streaming into;
    /// `lastSeq` the hub's number for the last event rendered, which is what
    /// a re-attach resumes from.
    @ObservationIgnored private var replyRow: Int?
    @ObservationIgnored private var lastSeq = 0

    /// Whichever wait `resumeIfLive` can cut short: the task reading the
    /// current socket, or the one sleeping out a backoff. Never both.
    @ObservationIgnored private var reader: Task<Outcome, Never>?
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    /// Set by `resumeIfLive` so the wait it cancelled reports `.kicked`
    /// rather than looking like a socket that died, or a Stop.
    @ObservationIgnored private var kicked = false
    /// Set by `detach` so the reader it cancelled reports `.detached`: the
    /// socket was closed ON PURPOSE and the turn is to wait for the app's
    /// return, not to re-attach and not to be marked dropped.
    @ObservationIgnored private var parked = false

    /// `attach` is for the voice chat (`AtlasVoice`), which re-opens a thread
    /// by the conversation id it saved rather than from a history row. Every
    /// other caller leaves it `.none`.
    init(agent: Agent, title: String, attach: Attach = .none, streams: Streams = .live) {
        self.agent = agent
        self.title = title
        self.attach = attach
        self.streams = streams
    }

    /// Loads a conversation clicked in history and arms the FIRST send to
    /// resume it. `attach` is set to `.sessionId`, not `.conversation` -
    /// `transcript.id` is the agent-native session id (what the hub's
    /// `/api/conversations` list addresses a thread by), and per `Attach`'s
    /// contract that key is only valid to open a thread with; `run` replaces
    /// it with `.conversation` as soon as the resumed turn's `conversation`
    /// event arrives, which is what keeps turn two from re-sending a
    /// `sessionId` the hub may already consider stale.
    func load(transcript: Transcript) {
        bubbles = transcript.messages.map {
            Bubble(kind: $0.role == "user" ? .you : .assistant, text: $0.text)
        }
        attach = .sessionId(transcript.id)
    }

    /// Stops the turn in flight, on the hub as well as locally. THE PENCIL'S,
    /// AND NOTHING ELSE'S - see `ChatShell`'s new-chat button for which
    /// gestures cancel and which deliberately do not.
    ///
    /// CANCEL, DO NOT MERELY ABANDON. A dead socket no longer stops a turn -
    /// that is the entire point of the hub's detachable turns, and it is what
    /// lets a locked phone come back to a finished answer - so walking away
    /// without this leaves a `claude` child running and holding one of only
    /// three hub slots until it times out. Do that three times during long
    /// turns and the next send comes back "The hub is busy with other turns"
    /// with nothing visibly running to explain it.
    ///
    /// NO STATE RESET HERE, unlike the in-place "New" this is the surviving
    /// half of. The caller is about to mint a fresh `ChatTarget`, which rebuilds
    /// the view and this whole model through `.id()`; clearing `bubbles`,
    /// `attach` and the rest first would be writing to an object one frame away
    /// from being discarded. `stopped` is set all the same, and only so the turn
    /// ends as a stop: a voice turn asked here then ends quietly instead of
    /// saying "The connection dropped" over the fresh chat.
    ///
    /// EXACTLY `stop`, so a pencil pressed before the hub has named the turn
    /// waits for its id to cancel it, as a Stop does, rather than hanging up
    /// and leaving the `claude` child running. The view is gone by then, and
    /// that is fine: the running turn's `Task` holds this model until the
    /// cancel has landed.
    func cancelLiveTurn() { stop() }

    /// The composer's Stop button: end this turn and STAY HERE, keeping
    /// whatever was written so far.
    ///
    /// THE OTHER HALF OF `cancelLiveTurn`, and the difference is entirely in
    /// what happens next rather than in what is stopped. The pencil cancels a
    /// model that is one frame from being thrown away, so it can leave any
    /// state it likes behind; this one cancels the model the user is still
    /// looking at, which is why `stopped` has to be latched first - without it
    /// the stream ending is indistinguishable from the socket dying, and `run`
    /// would mark the half-written answer "Connection dropped" and then spend
    /// five minutes trying to re-attach to a turn this call just killed.
    ///
    /// `busy` IS NOT CLEARED HERE, deliberately, even though the button would
    /// feel crisper if it were. `run`'s `defer` owns that flag, and clearing it
    /// early would re-enable Send while the old turn is still unwinding - two
    /// turns in one model, with the second one's events folding into the
    /// first one's `toolRows`. The unwind is one loop iteration; the wait is
    /// not perceptible.
    ///
    /// A STOP BEFORE THE HUB HAS NAMED THE TURN KEEPS THE SOCKET OPEN. With no
    /// `liveTurnId` there is nothing to cancel on the hub, and hanging up only
    /// detaches: the `claude` child the hub has already started runs on - a
    /// misheard lock-screen command still gets carried out. So this waits for
    /// the `conversation` event, the first thing the hub sends, and `apply`
    /// cancels the turn by its id then. The cost is that such a Stop takes up
    /// to one round trip to land. If the event never comes, the socket is torn
    /// down after five seconds regardless. The pencil's `cancelLiveTurn` comes
    /// through here too.
    func stop() {
        guard busy else { return }
        stopped = true
        guard liveTurnId == nil else {
            endTurn()
            return
        }
        let pending = turn
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            // Still the same turn: a new one started since must not be torn
            // down by an old Stop.
            guard let self, self.turn == pending else { return }
            self.turn?.cancel()
        }
    }

    /// Stop the run, on the hub as well as locally, once the hub has named it.
    /// `stopped` is set first.
    private func endTurn() {
        if let id = liveTurnId { Task { [self] in await streams.cancel(id) } }
        turn?.cancel()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !uploading else { return }
        guard !tray.isEmpty else {
            guard !text.isEmpty else { return }
            draft = ""
            start(text)
            return
        }
        // ALL OR NOTHING: the draft and the tray stay put until every photo
        // is on atlas, so a failure costs a tap on Send, not a retyped message.
        uploading = true
        Task {
            defer { uploading = false }
            guard let paths = await tray.uploadAll(upload: uploadPhoto) else { return }
            let said = text.isEmpty ? PhotoMessage.defaultText(count: paths.count) : text
            draft = ""
            tray.clear()
            start(PhotoMessage.compose(text: said, paths: paths))
        }
    }

    /// Everything `send()` does after taking the draft, shared with `ask` -
    /// which must NOT touch the draft: a spoken question landing on the chat
    /// on screen would otherwise wipe whatever was half-typed there.
    private func start(_ text: String) {
        bubbles.append(Bubble(kind: .you, text: text))
        busy = true
        // Cleared per turn, not per model: one chat can be stopped and then
        // asked something else, and a latched flag would make the NEXT turn's
        // ordinary failures render as deliberate stops.
        stopped = false
        startedAt = Date()
        toolRows = [:]
        turn = Task { await run(text) }
    }

    /// Voice's way in: the same turn `send()` runs, from words that were
    /// spoken rather than typed, returning once that turn has ENDED - done,
    /// failed, or stopped. False, having sent nothing, if a turn is already
    /// running or the words are blank: either way no turn of THIS ask's would
    /// start, and the caller would be awaiting somebody else's turn or none.
    func ask(_ text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return false }
        start(text)
        await turn?.value
        return true
    }

    /// One turn, across however many sockets it takes.
    ///
    /// THE SOCKET IS NOT THE TURN. iOS suspends a backgrounded app within
    /// seconds and the stream dies with a transport error; the hub keeps
    /// generating and buffers what it produces, so the right response to that
    /// error is to wait and re-attach from the last seq rendered - not to show
    /// "the connection dropped" over an answer that is still being written.
    ///
    /// TWO WAYS BACK ONTO THE TURN, and the difference is what the user sees.
    /// A socket that dies while the app is on screen is a real fault: the loop
    /// says "Reconnecting…", backs off, and re-attaches. A socket that died
    /// because the app was BACKGROUNDED is not a fault at all, and used to be
    /// treated as one - the chat learned of it only when URLSession gave up on
    /// the dead stream, up to thirty seconds idle, and then slept a backoff on
    /// top. `LiveTurns` now calls `resumeIfLive` the moment the app is back,
    /// which cuts whichever wait is in progress short and re-attaches at once,
    /// with no "Reconnecting…" unless that immediate re-attach itself fails.
    /// Timers do not fire while the app is suspended, so a backoff that was
    /// running when iOS froze the app is exactly what gets cut.
    private func run(_ text: String) async {
        LiveTurns.shared.began(self)
        defer {
            busy = false
            reconnecting = false
            liveTurnId = nil
            startedAt = nil
            lastTurnEnded = Date()
            LiveTurns.shared.ended(self)
        }
        replyRow = nil
        lastSeq = 0
        var attempt = 0
        // Whether the stream being read is a re-attach rather than the send. A
        // 404 means different things on each - see `.gone` below.
        var attached = false

        var stream = streams.send(agent, text, attach)
        while true {
            switch await consume(stream) {
            case .done:
                // The ping for an answer that landed while the app was away
                // but still connected - the hub's own push only covers a
                // turn nobody was watching. BEFORE `defer` clears the id.
                LiveTurns.shared.finished(self)
                return

            case .ended:
                // The stream ended without a `done`. On an ATTACH that means the
                // turn is over and its terminal event was before `from`; on a
                // fresh send it means the socket closed early - or the user
                // pressed Stop, which is what `finish` separates out.
                finish(nil)
                return

            case .kicked:
                // Back on screen. Straight onto the turn from the last event
                // rendered. The attempt budget starts over: a fresh foreground
                // is fresh evidence that the network is there.
                guard let id = liveTurnId else {
                    finish(nil)
                    return
                }
                attempt = 0
                attached = true
                stream = streams.attach(id, lastSeq + 1)

            case .detached:
                // The app's background time ran out and `LiveTurns` closed
                // the socket cleanly, so the hub sees the hang-up, counts
                // nobody watching, and pushes when the turn finishes. Nothing
                // to do until the app is back - `park` returns on that kick -
                // and then it is the same re-attach as any other return.
                guard let id = liveTurnId else {
                    finish(nil)
                    return
                }
                await park()
                if Task.isCancelled {
                    finish(nil)
                    return
                }
                attempt = 0
                attached = true
                stream = streams.attach(id, lastSeq + 1)

            case .failed(let error):
                // A DELIBERATE STOP LOOKS EXACTLY LIKE A DEAD SOCKET from here:
                // cancelling the task tears the stream down, and URLSession's
                // `.cancelled` maps to `.other`, which is one of the two cases
                // the reconnect loop below exists for. Without this line,
                // pressing Stop marks the answer "connection dropped" and then
                // re-attaches to the turn it just cancelled.
                guard !stopped else {
                    finish(nil)
                    return
                }
                guard let e = error as? ClaudeError else {
                    // The stream died in a way ClaudeError does not name. KEEP
                    // the partial answer and mark it, and never auto-retry the
                    // MESSAGE - a retry re-runs whatever tools already ran.
                    finish(error)
                    return
                }
                switch e {
                case .gone where attached:
                    // ONLY THE TURN'S BUFFER IS GONE, not the thread. The app
                    // was away past the hub's retention; the answer finished
                    // into the transcript on atlas and the conversation is
                    // still open there. So `attach` and `threadId` are KEPT -
                    // forgetting them here made the next message silently
                    // start a new thread under the old title. A send that 404s
                    // (below) is the case that really means the thread is gone.
                    if let i = replyRow { bubbles[i].incomplete = true }
                    bubbles.append(
                        Bubble(
                            kind: .error,
                            text: "The hub had let go of the rest of this answer by the time the app came back. The whole answer is in this thread's history."))
                    return
                case .gone:
                    // The thread aged out of the hub, or was never there. Keep
                    // whatever landed and stop pretending.
                    attach = .none
                    // Nothing may save this thread to continue - see
                    // AtlasVoice. Forgetting it is the safe default, since the
                    // worst case is a fresh thread next time.
                    threadId = nil
                    finish(e)
                    return
                case .unreachable, .other, .locked:
                    // Transport. THIS is the backgrounded case, and it is the
                    // one the whole feature exists for. A Keychain that locked
                    // under a RE-ATTACH waits the same way: the lock is
                    // temporary and the hub is still buffering the answer. On
                    // a fresh send there is no `liveTurnId`, so it fails at
                    // once with its own message.
                    guard let id = liveTurnId, attempt < 40 else {
                        finish(e)
                        return
                    }
                    reconnecting = true
                    attempt += 1
                    // 2, 4, 8, 8... - forty attempts is a little over five
                    // minutes of trying, well past a lock screen and nowhere
                    // near the hub's two-hour retention of a finished turn.
                    let backoff = min(8.0, pow(2.0, Double(min(attempt, 3))))
                    let why = await sleep(backoff)
                    // Cancelled WHILE WAITING - the pencil, or Stop pressed
                    // during a reconnect. `finish` rather than a bare return so
                    // a half-written answer is still marked; a bare one leaves
                    // it looking finished.
                    if Task.isCancelled {
                        finish(nil)
                        return
                    }
                    // Parked mid-backoff: the background time ran out with the
                    // socket already dead. Wait for the app, as `.detached`.
                    if why == .parked {
                        await park()
                        if Task.isCancelled {
                            finish(nil)
                            return
                        }
                    }
                    if why != .elapsed {
                        attempt = 0
                        reconnecting = false
                    }
                    attached = true
                    stream = streams.attach(id, lastSeq + 1)
                default:
                    bubbles.append(Bubble(kind: .error, text: e.localizedDescription))
                    return
                }
            }
        }
    }

    /// How one socket's worth of a turn ended.
    private enum Outcome {
        case done, ended, kicked, detached
        case failed(Error)
    }
    /// How a wait in the loop ended: on its own, or cut by `resumeIfLive` or
    /// `detach`.
    private enum Wait { case elapsed, kicked, parked }

    /// Read one stream into the transcript until it ends, however it ends.
    ///
    /// A TASK OF ITS OWN, so that something other than the stream can end the
    /// wait: `resumeIfLive` cancels it, and the outcome is then `.kicked`
    /// whatever the stream itself reported. The turn's own cancellation - Stop,
    /// the pencil - reaches the reader through the cancellation handler, so a
    /// Stop still ends this exactly as it did when `run` read the stream
    /// itself.
    private func consume(_ stream: AsyncThrowingStream<SSEEvent, Error>) async -> Outcome {
        kicked = false
        parked = false
        let task = Task { [self] () -> Outcome in
            do {
                for try await ev in stream {
                    if Task.isCancelled { return .ended }
                    if let s = ev.seq { lastSeq = s }
                    reconnecting = false
                    if apply(ev) { return .done }  // `done` landed
                }
                return .ended
            } catch {
                return .failed(error)
            }
        }
        reader = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        reader = nil
        return parked ? .detached : kicked ? .kicked : outcome
    }

    /// Sleep out a backoff, or as long as `park` asks, unless cut short.
    private func sleep(_ seconds: Double) async -> Wait {
        kicked = false
        parked = false
        let task = Task { _ = try? await Task.sleep(for: .seconds(seconds)) }
        sleeper = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        sleeper = nil
        return parked ? .parked : kicked ? .kicked : .elapsed
    }

    /// Wait for the app to come back. Returns on `resumeIfLive`'s kick or on
    /// the turn's own cancellation; a second `detach` while already parked
    /// simply keeps waiting. Timers do not run while the app is suspended, so
    /// the week is a formality - what ends this is the return.
    private func park() async {
        while true {
            let why = await sleep(7 * 24 * 3600)
            if why != .parked || Task.isCancelled { return }
        }
    }

    /// The app is about to be frozen with this turn still running: close the
    /// socket NOW, on purpose, and wait for the return. Without this the
    /// phone's kernel keeps acknowledging the hub's heartbeats on behalf of a
    /// frozen app, the hub counts a watcher that is not there, and its
    /// "finished" push - which bails while anyone is watching - never comes.
    /// Same guard as `resumeIfLive`: a turn the hub has not named has no id to
    /// come back by, and a Stop is already ending it. Called by `LiveTurns`.
    func detach() {
        guard busy, liveTurnId != nil, !stopped else { return }
        parked = true
        // Not "Reconnecting…" while parked: nothing is being tried until the
        // app is back, and the return re-attaches before anyone could read it.
        reconnecting = false
        reader?.cancel()
        sleeper?.cancel()
    }

    /// The app is back on screen after the background: get back onto the turn
    /// NOW, from the last event rendered, rather than waiting for the old
    /// socket to be declared dead and a backoff to run out. Nothing to do when
    /// no turn is live, when the hub has not yet named the one that is (there
    /// is no id to attach by - the send's own socket is still the way in), or
    /// when a Stop is already unwinding it. Called by `LiveTurns`.
    func resumeIfLive() {
        guard busy, liveTurnId != nil, !stopped else { return }
        kicked = true
        reconnecting = false
        reader?.cancel()
        sleeper?.cancel()
    }

    /// How a turn ends when it does not end with a `done` event.
    ///
    /// THREE ENDINGS, ONE PLACE. This used to be four copies of the same two
    /// lines scattered through `run`'s exits, which is how the stop path came
    /// to need a change in four places at once - and why one of them (the
    /// cancelled-during-backoff return) had silently never marked the answer
    /// at all.
    private func finish(_ error: Error?) {
        if stopped {
            // NO ERROR BUBBLE, whatever `error` says. The user ended this; the
            // transport complaint that follows from that is noise.
            if let i = replyRow { bubbles[i].stopped = true }
            return
        }
        if let i = replyRow {
            bubbles[i].incomplete = true
        } else if let error {
            let message = (error as? ClaudeError)?.localizedDescription ?? error.localizedDescription
            bubbles.append(Bubble(kind: .error, text: message))
        }
    }

    /// Fold one event into the transcript. Returns true when the turn is over.
    ///
    /// Extracted from `run` because the reconnect loop applies events from two
    /// different streams, and a second copy of this switch is a second place
    /// for the tool-row bookkeeping to drift.
    private func apply(_ ev: SSEEvent) -> Bool {
        switch ev.event {
        case "conversation":
            if let id = try? JSONDecoder().decode(ClaudeConversation.self, from: ev.data).conversation {
                attach = agent.attach(afterConversationEvent: id)
                // The same string for Claude and for Hermes: the hub's attach
                // and cancel routes take one id space, so no agent branch.
                liveTurnId = id
                threadId = id
                onThread?(id)
                // STOPPED BEFORE THIS ARRIVED - see `stop`. Now there is an id
                // to cancel on the hub, so cancel it and end the turn the way
                // any stop ends: marked stopped, no error.
                if stopped {
                    Task { [self] in await streams.cancel(id) }
                    finish(nil)
                    return true
                }
            }

        case "gap":
            // The hub dropped the middle of a very long answer to stay inside
            // its buffer cap. Say so where it happened rather than stitching
            // two unrelated halves together silently.
            if let i = replyRow { bubbles[i].text += "\n\n… (some output was dropped) …\n\n" }

        case "text":
            guard let t = try? JSONDecoder().decode(ClaudeText.self, from: ev.data) else { break }
            // Stream into the CURRENT bubble rather than waiting for done -
            // that responsiveness is the whole point of SSE.
            if let i = replyRow {
                bubbles[i].text += t.text
            } else {
                bubbles.append(Bubble(kind: .assistant, text: t.text))
                replyRow = bubbles.count - 1
            }

        // Hermes never emits `tool`/`tool_result` - these two cases simply
        // never match for a Hermes agent's stream, so there is no agent check
        // to add here.
        case "tool":
            guard let t = try? JSONDecoder().decode(ClaudeTool.self, from: ev.data) else { break }
            bubbles.append(Bubble(kind: .tool, text: t.summary, toolName: t.name))
            toolRows[t.id] = bubbles.count - 1
            onTool?(t.name)
            replyRow = nil  // text after a tool starts a new bubble

        case "tool_result":
            guard let t = try? JSONDecoder().decode(ClaudeToolResult.self, from: ev.data),
                let i = toolRows[t.id]
            else { break }
            bubbles[i].toolResult = t.text

        case "done":
            let d = try? JSONDecoder().decode(ClaudeDone.self, from: ev.data)
            if let msg = d?.error { bubbles.append(Bubble(kind: .error, text: msg)) }
            if let denials = d?.denials, !denials.isEmpty {
                bubbles.append(
                    Bubble(
                        kind: .error,
                        text: "Claude was denied: \(denials.joined(separator: ", "))"))
            }
            return true

        default: break
        }
        return false
    }
}

struct ClaudeView: View {
    /// The scroll id of the thinking indicator. A constant rather than a
    /// literal at each of the three places that reach for it, because a typo
    /// in one of them is a scroll that silently does nothing.
    private static let thinkingID = "thinking"

    /// Nothing `send()` would send - the same trim, so a newline-only draft
    /// shows Talk rather than a Send that does nothing.
    /// Photos alone are something to send, so they turn Talk into Send too.
    private var draftIsEmpty: Bool {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.tray.isEmpty
    }

    /// Send, Talk and Stop share one slot; this is the width they all take.
    private static let composerButtonWidth: CGFloat = 58

    @State private var model: ChatModel
    @State private var resumeStarted = false
    /// True while a resumed thread's transcript failed to load. `attach`
    /// stays `.none` in that state - `ChatModel` never heard about the
    /// thread it was supposed to resume - so sending anyway would silently
    /// start a brand-new conversation under the old title rather than
    /// continuing the one the user tapped. The composer is replaced with a
    /// retry bar instead, so there is no way to type a turn into that gap.
    @State private var resumeFailed = false
    @FocusState private var typing: Bool
    @State private var picked: [PhotosPickerItem] = []

    /// The row clicked in history, if this chat is resuming one rather than
    /// starting fresh. Only the three fields `HubClient.transcript` needs
    /// travel here - not the whole `Conversation` - since `agent`/`title`
    /// above already carry everything else this view uses.
    private let resume: ResumeRef?

    /// The shell's handle on whichever chat is on screen. NOT OPTIONAL and
    /// with no default, so that the one construction site - `ChatShell` - cannot
    /// forget it. An `= nil` here would compile everywhere and disable the
    /// pencil's cancel with nothing to notice.
    private let handle: ChatHandle

    /// Built in exactly one place, `ChatShell`, from the fields of a
    /// `ChatTarget`: a fresh chat leaves `resume` nil, and a thread opened from
    /// the drawer carries the clicked row's identity, which the `.task` below
    /// turns into a `HubClient.transcript` fetch and a `model.load(transcript:)`
    /// call once the view appears.
    ///
    /// NO `NavigationStack` HERE, on purpose, unlike this view's previous life
    /// as the Claude tab's own root - and there is none anywhere above it
    /// either. `ChatShell` hosts this view directly and nothing in this app
    /// pushes: `HistoryDrawer` opens a thread by handing the shell a new
    /// `ChatTarget`, which rebuilds this view through `.id()` rather than
    /// putting a second screen on a stack. That is also why there is no
    /// `.navigationTitle` and no `.toolbar` in the body below - with no stack
    /// to attach to they would be silently inert, and the shell's own top bar
    /// is what actually carries the title and the "New" button.
    init(
        agent: Agent = .claude, title: String = "Claude",
        resume: ResumeRef? = nil, handle: ChatHandle
    ) {
        let model = ChatModel(agent: agent, title: title)
        DemoMode.seed(model)
        _model = State(initialValue: model)
        self.resume = resume
        self.handle = handle
        _resumeFailed = State(initialValue: DemoMode.resumeFailed)
    }

    /// A chat whose model already exists: the voice chat. `AtlasVoice` owns it
    /// because its turns run with no view at all, from a locked phone, and this
    /// view only shows it. No demo seeding and no resume - it is neither a
    /// screenshot fixture nor a history row.
    init(model: ChatModel, handle: ChatHandle) {
        _model = State(initialValue: model)
        self.resume = nil
        self.handle = handle
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // A FRESH chat with nothing in it yet says so, in Deck's
                    // dashed "nothing here yet" box. Not for a resumed thread:
                    // its bubbles are empty only until the transcript lands,
                    // and "nothing asked yet" over a thread with a history
                    // would be a lie for exactly that long.
                    if resume == nil && model.bubbles.isEmpty && !model.busy {
                        DeckEmpty(
                            label: "New chat · \(model.agent.deckName)",
                            title: "Nothing asked yet",
                            message: "Type or tap Talk below. The answer streams in here, and keeps running if you lock the phone.")
                    }
                    ForEach(model.bubbles) { b in BubbleRow(bubble: b, agent: model.agent).id(b.id) }
                    // What a voice session is hearing for this chat, live.
                    LiveHeardRow(model: model, proxy: proxy)
                    // BELOW THE TRANSCRIPT, NOT INSIDE IT. The obvious
                    // alternative is a placeholder `Bubble` appended on send
                    // and removed on done, and it is worse in two ways that
                    // only show up later: it would be indexable by `replyRow`
                    // and the tool bookkeeping, and it would have to be
                    // removed on every one of `run`'s exits - including the
                    // ones that return from inside a catch.
                    if model.busy, let started = model.startedAt {
                        ThinkingRow(startedAt: started, reconnecting: model.reconnecting)
                            .id(Self.thinkingID)
                    }
                }
                .padding(Theme.sp4)
            }
            // OPENS AT THE LATEST, for the one chat that is built already
            // long: the voice chat, whose model `AtlasVoice` kept across the
            // rebuild. Every other chat starts empty (demo mode aside), so
            // this does nothing for them - a resumed thread's transcript
            // lands after, and the `onChange` below scrolls it.
            //
            // NOT `.defaultScrollAnchor(.bottom, for: .initialOffset)`, the
            // obvious iOS 18 line. It was tried and measured: it anchors on
            // the LazyVStack's ESTIMATED height, and the demo conversation
            // opened ~180pt past its end, a blank band between the last answer
            // and the composer. Scrolling to a row by id, the way the two
            // `onChange`s below already do, lands exactly.
            .onAppear {
                if model.busy {
                    proxy.scrollTo(Self.thinkingID, anchor: .bottom)
                } else if let last = model.bubbles.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            // Swiping the transcript puts the keyboard away. Without this
            // the keyboard covers the tab bar and there is no way off this
            // screen short of killing the app.
            .scrollDismissesKeyboard(.interactively)
            // Tapping the transcript also dismisses. This carries the case
            // the swipe cannot: a fresh conversation has nothing to scroll,
            // and the keyboard covers the tab bar, so without SOME way out
            // the only escape from this screen is killing the app.
            .contentShape(.rect)
            .onTapGesture { typing = false }
            .onChange(of: model.bubbles.count) {
                // The indicator is the LAST thing in the stack while a turn is
                // running, so scrolling to the last bubble would stop one row
                // short and leave it under the composer - at exactly the moment
                // it is the only thing worth seeing.
                if model.busy {
                    withAnimation { proxy.scrollTo(Self.thinkingID, anchor: .bottom) }
                } else if let last = model.bubbles.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            // Sending adds a bubble AND starts the indicator in the same frame,
            // so `bubbles.count` alone scrolls to a row that is about to have
            // something under it. This catches the other edge too: when the turn
            // ends the indicator disappears and the answer should settle at the
            // bottom rather than leaving a gap where it was.
            .onChange(of: model.busy) {
                withAnimation {
                    // NOT A TERNARY over the two ids - one is a String and the
                    // other a UUID, and unifying them costs an AnyHashable box
                    // at both call sites to save two lines.
                    if model.busy {
                        proxy.scrollTo(Self.thinkingID, anchor: .bottom)
                    } else if let last = model.bubbles.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        // NO `.navigationTitle` AND NO TOOLBAR. ChatShell owns the top bar, and
        // there is no NavigationStack above this view for either to attach to -
        // both would be silently inert, and an inert `.navigationTitle` is
        // worse than none because it reads as the title that is on screen.
        // "New" lives in the shell's bar and works by replacing the shell's
        // ChatTarget, which rebuilds this view outright.
        .safeAreaInset(edge: .bottom) {
            if resumeFailed {
                HStack(spacing: Theme.sp3) {
                    Text("This conversation didn't load.")
                        .font(Deck.body)
                        .foregroundStyle(Deck.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Retry") { Task { await loadResume() } }
                        .buttonStyle(.deckPrimary)
                }
                .padding(.horizontal, Theme.sp4)
                .padding(.vertical, Theme.sp3)
                .deckBar(.bottom)
            } else {
                VStack(spacing: 0) {
                    if !model.tray.isEmpty {
                        PhotoTrayStrip(tray: model.tray, locked: model.uploading)
                    }
                    HStack(alignment: .bottom, spacing: Theme.sp3) {
                        if model.canAttach {
                            PhotosPicker(
                                selection: $picked, maxSelectionCount: max(model.tray.room, 1), matching: .images
                            ) {
                                Image(systemName: "paperclip").font(.system(size: 18, weight: .semibold))
                                    .frame(width: 32, height: 40)
                            }
                            .disabled(
                                model.busy || model.uploading || model.tray.room == 0 || VoiceSession.shared.isActive
                            )
                            .accessibilityLabel("Attach photos")
                        }
                        let placeholder =
                            model.reconnecting
                            ? "Reconnecting…"
                            : model.busy
                                ? "Still answering…"
                                : "Ask \(model.title)"
                        // The prompt in `muted`, set explicitly: the system's own
                        // placeholder grey is under 3:1 on Deck's surface, and this
                        // line is the only thing that says a turn is running when
                        // the transcript is scrolled away from the indicator.
                        TextField(
                            placeholder, text: $model.draft,
                            prompt: Text(placeholder).foregroundStyle(Deck.muted),
                            axis: .vertical
                        )
                        .textFieldStyle(DeckFieldStyle())
                        .lineLimit(1...5)
                        // Under the VoiceBar while a session runs, and a typed
                        // turn there would be a second one in this chat.
                        // `isActive`, not `phase`: it changes twice a session,
                        // not on every word heard. Locked while photos upload
                        // too: `send` already took the text, and clears the
                        // draft when the upload lands.
                        .disabled(model.busy || model.uploading || VoiceSession.shared.isActive)
                        .focused($typing)
                        // Collapses the QuickType suggestion strip. The bar is
                        // the system's, not ours, and this is the only lever
                        // SwiftUI exposes over it - autocorrect goes with it.
                        .autocorrectionDisabled()
                        // ONE BUTTON THAT CHANGES JOB, not a Stop button beside
                        // Send. Send is dead while a turn runs and Stop is dead
                        // while one is not, so two controls would mean one greyed
                        // dud on screen at all times - and they would fight for the
                        // same thumb position. Same place, same size, one meaning
                        // at a time.
                        //
                        // THE SAME WIDTH IN BOTH JOBS, so the field beside it does
                        // not jump sideways the moment a turn starts or ends.
                        if model.busy {
                            Button {
                                model.stop()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .frame(minWidth: Self.composerButtonWidth)
                            }
                            // The crit fill IS the colour now, from the style -
                            // there is no tint left to set, and a Deck button
                            // ignores one anyway.
                            .buttonStyle(.deckDanger)
                            // The whole point of this control is that it works
                            // at the moment everything else in the composer is
                            // disabled. It takes no `.disabled` at all.
                            .accessibilityLabel("Stop answering")
                        } else if draftIsEmpty {
                            // AN EMPTY DRAFT TURNS SEND INTO TALK, in the same slot
                            // and at the same width, the way Messages does it. The
                            // question goes into THIS chat - a mic beside a text
                            // field means "say what I'd have typed here" - and only
                            // a spoken question is read back aloud.
                            Button {
                                typing = false
                                VoiceSession.shared.trigger(ChatModelTurn(model))
                            } label: {
                                Label("Talk", systemImage: "mic.fill")
                                    .frame(minWidth: Self.composerButtonWidth)
                            }
                            .buttonStyle(.deckPrimary)
                            .accessibilityLabel("Ask \(model.title) out loud")
                        } else {
                            // Never disabled now: an empty draft shows Talk instead,
                            // so the disabled-shadow padding this used to carry has
                            // nothing left to hold open.
                            Button {
                                model.send()
                                typing = false
                            } label: {
                                Label(
                                    model.uploading ? "Sending" : "Send",
                                    systemImage: model.uploading ? "arrow.up.circle" : "arrow.up"
                                )
                                .frame(minWidth: Self.composerButtonWidth)
                            }
                            .buttonStyle(.deckPrimary)
                            .disabled(model.uploading)
                        }
                    }
                }
                .padding(.horizontal, Theme.sp4)
                .padding(.vertical, Theme.sp3)
                .deckBar(.bottom)
                // Covered by the VoiceBar, so out of VoiceOver's reach too.
                .accessibilityHidden(VoiceSession.shared.isActive)
                .onChange(of: picked) {
                    let items = picked
                    guard !items.isEmpty else { return }
                    picked = []
                    Task {
                        for item in items {
                            if let raw = try? await item.loadTransferable(type: Data.self),
                                let jpeg = PhotoJPEG.jpeg(from: raw)
                            {
                                model.tray.add(jpeg)
                            }
                        }
                    }
                }
            }
        }
        // ON APPEAR, NOT IN `init`, AND NOT IN `.task`. `init` would hand over a
        // throwaway model (see `ChatHandle.register`), and `.task` runs its body
        // asynchronously after the view is already on screen - a window, however
        // short, in which the pencil is visible and cancels nothing. `onAppear`
        // runs synchronously during the appearance pass, before any of it can be
        // tapped. `model` here is the `@State`-resolved instance, which is the
        // one that will actually run turns.
        .onAppear { handle.register(model) }
        .task {
            // Guarded the same way `DirectoryView`'s listing load is: `.task`
            // can re-run on things like a scene-phase change, and re-fetching
            // would either duplicate a load already in flight or, worse,
            // overwrite bubbles from a turn the user has since sent.
            guard resume != nil, !resumeStarted else { return }
            resumeStarted = true
            await loadResume()
        }
    }

    /// Fetches `resume`'s transcript and loads it, or marks the load failed.
    /// Shared by the initial `.task` and the retry button so a flaky first
    /// attempt is not the only chance to open this thread.
    private func loadResume() async {
        guard let resume else { return }
        do {
            let t = try await HubClient.shared.transcript(
                source: resume.source, node: resume.node, id: resume.id)
            model.load(transcript: t)
            resumeFailed = false
        } catch {
            // A blank screen or a hang here would be indistinguishable from
            // the hub just being slow, so the failure has to land as a
            // bubble like any other - there is nowhere else in this view for
            // it to go. `resumeFailed` is the part the bubble alone can't
            // do: it swaps out the composer so nothing can be typed into a
            // thread `attach` never actually heard about.
            let message = (error as? HubError)?.localizedDescription ?? error.localizedDescription
            model.bubbles = [Bubble(kind: .error, text: "Couldn't load this conversation: \(message)")]
            resumeFailed = true
        }
    }
}

struct BubbleRow: View {
    let bubble: Bubble
    /// Who is answering in this chat - every agent message carries its name
    /// and colour. One agent per chat, so this is the chat's, not the bubble's.
    let agent: Agent
    @State private var expanded = DemoMode.expandsTools

    var body: some View {
        switch bubble.kind {
        case .you:
            // A photo turn is stored as text + [photo] lines (PhotoMessage);
            // show the photos, and only the words the user typed.
            let parsed = PhotoMessage.parse(bubble.text)
            VStack(alignment: .trailing, spacing: Theme.sp2) {
                if !parsed.paths.isEmpty {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(96), spacing: Theme.sp2), count: min(parsed.paths.count, 3)),
                        alignment: .trailing, spacing: Theme.sp2
                    ) {
                        ForEach(parsed.paths, id: \.self) { HubPhoto(path: $0) }
                    }
                }
                // Ink fill, inverse text: the one solid block in the transcript,
                // so what you said is findable at a glance without a colour.
                HStack {
                    Spacer(minLength: 40)
                    Text(parsed.text)
                        .font(Theme.message)
                        .foregroundStyle(Deck.inkInverse)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Theme.sp3)
                        .deckTile(fill: Deck.ink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: Theme.sp2) {
                AgentTag(agent: agent)
                ForEach(Array(ChatText.segments(bubble.text).enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .prose(let p):
                        Text(ChatText.prose(p))
                            .font(Theme.message)
                            .foregroundStyle(Deck.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    case .code(let language, let code):
                        DeckCodeBlock(language: language, code: code)
                    }
                }
                // A STOP OUTRANKS AN `incomplete`, and both can be set: a turn
                // stopped mid-reconnect has already been marked dropped by an
                // earlier pass. What the user did is the truer of the two.
                //
                // Shape-coded like every Deck status: ○ for a stop you chose,
                // ◆ for a drop you did not, so the two read apart in greyscale.
                if bubble.stopped {
                    note(.idle, "You stopped this answer.", Deck.muted)
                } else if bubble.incomplete {
                    note(.warn, "Connection dropped — this answer is incomplete.", Deck.warnInk)
                }
            }
            .padding(.leading, Theme.sp3 + Theme.agentEdge)
            .padding([.trailing, .vertical], Theme.sp3)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The agent's colour as a thin edge, INSIDE the ink border and
            // always beside the AgentTag that names it.
            .overlay(alignment: .leading) {
                Rectangle().fill(agent.deckColour).frame(width: Theme.agentEdge)
                    .accessibilityHidden(true)
            }
            .deckTile()
        case .tool:
            // Collapsed by default: the point of the phone app is the answer,
            // not the transcript.
            DisclosureGroup(isExpanded: $expanded) {
                Text(bubble.toolResult.isEmpty ? "(no output yet)" : bubble.toolResult)
                    .font(Theme.code)
                    .foregroundStyle(bubble.toolResult.isEmpty ? Deck.muted : Deck.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("\(bubble.toolName) · \(bubble.text)", systemImage: "gearshape")
                    .font(Theme.toolLine)
                    .foregroundStyle(Deck.ink)
                    .lineLimit(1)
            }
            .disclosureGroupStyle(DeckDisclosureStyle())
        case .error:
            DeckAlert(.crit, message: bubble.text)
        }
    }

    private func note(_ status: DeckStatus, _ text: String, _ colour: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            DeckDot(status, size: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            Text(text)
                .font(Deck.sans(12.5, .bold, relativeTo: .footnote))
                .foregroundStyle(colour)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
