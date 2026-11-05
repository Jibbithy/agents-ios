// Agents/Voice/VoiceSession.swift
import Foundation
import os

/// Where a spoken question is. The in-app `VoiceBar` and the Live Activity
/// both draw exactly this, so the two can never disagree about what is
/// happening.
enum VoicePhase: Equatable, Sendable {
    case idle
    case listening(heard: String)
    case thinking(tool: String?)
    case speaking(String)
    case failed(String)

    var isIdle: Bool { self == .idle }

    /// Listening, whatever has been heard so far.
    var isListening: Bool {
        if case .listening = self { true } else { false }
    }

    /// One word for the state: the Live Activity's compact slot, the bar's label.
    /// "Answer", NOT AN AGENT'S NAME: the composer mic asks Hermes and
    /// Calypso too, and the phase does not know whose answer it is reading.
    var label: String {
        switch self {
        case .idle: ""
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Answer"
        case .failed: "Voice"
        }
    }

    /// The line under the label.
    var detail: String {
        switch self {
        case .idle: ""
        case .listening(let heard): heard.isEmpty ? "Go ahead…" : heard
        case .thinking(let tool): tool.map { "Running \($0)…" } ?? "Working on it…"
        case .speaking(let text), .failed(let text): text
        }
    }

    /// An SF Symbol for the state.
    var symbol: String {
        switch self {
        case .idle: "mic"
        case .listening: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

/// How a question ended. Read off the chat - see `AskResult.from(_:)`.
enum AskResult: Equatable, Sendable {
    case reply(String)
    case failed(String)
    case stopped
}

enum VoiceError: Error {
    /// Speech or mic permission is missing, and cannot be asked for from here.
    case notAllowed
    /// The mic would not start - a phone call, another app recording.
    case micBusy
    /// The speech recogniser is missing, not available right now, or failed
    /// before it heard anything. Not the mic's fault, so not "Mic busy.".
    case speechUnavailable
}

/// Hears one question.
@MainActor protocol Listening: AnyObject {
    /// Listens until the speaker stops. Reports the transcript as it grows and
    /// returns all of it, or nil if nothing was said or the listen was cancelled.
    ///
    /// A PATIENT listen waits for a first word for as long as it takes,
    /// rather than giving up after five seconds of quiet; once words come it
    /// ends on the usual pause. It is the listen held open over an answer,
    /// which is quiet for as long as Atlas talks - see `VoiceSession` and
    /// `Endpointer.patient`. Only `finish`, `cancel` or words end one.
    func listen(patient: Bool, onWords: @escaping @MainActor @Sendable (String) -> Void) async throws -> String?
    /// Stop now and return what was heard - "press again to send".
    func finish()
    /// Stop now and return nil.
    func cancel()
}

extension Listening {
    /// A question, which gives up after five seconds of quiet. The default
    /// a protocol cannot spell out in the requirement itself.
    func listen(onWords: @escaping @MainActor @Sendable (String) -> Void) async throws -> String? {
        try await listen(patient: false, onWords: onWords)
    }
}

/// Reads text aloud.
@MainActor protocol Speaking: AnyObject {
    /// Returns when the text has been read, or when `stop()` cut it off.
    func speak(_ text: String) async
    /// The app's OWN words, not an answer: "Mic busy.", "Can't reach the
    /// rack." Said in whichever voice is always available - never one that
    /// has to be fetched, since what failed is often the thing that would
    /// have to fetch it. `stop()` and a press still work as they do for an
    /// answer.
    func say(_ text: String) async
    func stop()
    /// What is being read aloud now: the sentence or chunk playing and the
    /// one before it, or as near as the voice can tell. Empty when nothing
    /// is. What the mic hears of these may be Atlas's own voice coming back.
    var speakingNow: [String] { get }
}

extension Speaking {
    /// A voice that cannot tell what it is reading says nothing is.
    var speakingNow: [String] { [] }
    /// One voice, so the app's own words are read like anything else.
    func say(_ text: String) async { await speak(text) }
}

/// Asks one question of an agent. The composer asks the chat on screen;
/// every other trigger asks the voice chat.
@MainActor protocol Asking: AnyObject {
    func ask(_ text: String, onTool: @escaping @MainActor @Sendable (String) -> Void) async -> AskResult
    func cancel()
}

/// The shared audio session and the mic, on for exactly the length of one
/// session. Async because the first `begin` may have to ask for the mic.
@MainActor protocol VoiceAudio: AnyObject {
    /// Throws `VoiceError.notAllowed` without mic permission, `.micBusy` if
    /// the mic would not start. A begin that throws has undone itself, but
    /// `end()` is still called once the failure has been read aloud: reading
    /// it switches the session back on.
    func begin() async throws
    func end()
    /// What the phone plays is taken back out of what the mic hears. False
    /// with no mic open, and on a route where it would not turn on: then
    /// anything heard while an answer is read may be the answer itself.
    var echoCancelled: Bool { get }
}

/// Pending approvals (emails, texts, calendar changes), from the voice
/// session's side. MailApprovals in the app.
@MainActor protocol MailConfirming: AnyObject {
    func nextUnvoiced() async -> Approval?
    func approve(_ p: Approval) async -> String
    func cancel(_ p: Approval) async -> String
}

extension MailApprovals: MailConfirming {}

/// One spoken question, from the first word to the last word of the answer.
///
/// THE ONLY PLACE THAT KNOWS THE ORDER OF THE STEPS. Every trigger - the
/// composer mic, the Action Button, the wake word - calls `trigger(_:)` and
/// nothing else; what a trigger means depends on the phase it lands in (see
/// `trigger`). The four collaborators are protocols so the rules can be tested
/// on fakes, with no mic, speaker or hub.
@Observable @MainActor
final class VoiceSession {
    static let notAllowed = "Open Agents and tap the mic once to turn on voice."
    static let micBusy = "Mic busy."
    static let speechUnavailable = "Speech recognition isn't available right now."
    /// Said when a conversation has waited in silence long enough - see
    /// `SilenceWatch`. Said, not only chimed: from a locked phone a chime alone
    /// does not say the mic has closed.
    static let endingForSilence = "Ending voice chat."

    /// What a mic or a listen that failed says aloud. Anything that is not a
    /// `VoiceError` came from the audio side, so it is the mic's.
    static func message(for error: any Error) -> String {
        switch error as? VoiceError {
        case .notAllowed: notAllowed
        case .speechUnavailable: speechUnavailable
        case .micBusy, nil: micBusy
        }
    }

    private(set) var phase: VoicePhase = .idle {
        didSet {
            if phase != oldValue { onPhase?(phase) }
            if isActive == phase.isIdle { isActive = !phase.isIdle }
            // Every step, but not every word heard: those change the phase
            // several times a second and are not the log's business.
            let from = oldValue.logged
            let to = phase.logged
            if from != to { Logger.voice.notice("Voice: \(from, privacy: .public) -> \(to, privacy: .public)") }
        }
    }

    /// A session is under way: the composer under the bar goes inert.
    ///
    /// STORED, AND WRITTEN ONLY WHEN IT CHANGES, rather than computed from
    /// `phase`. A view that read `phase` would re-render on every partial
    /// transcript; this changes twice a session, at the start and the end.
    private(set) var isActive = false

    /// Every phase change, in order. The Live Activity's feed (Task 10).
    @ObservationIgnored var onPhase: ((VoicePhase) -> Void)?
    /// Awaited before every session's mic opens: whatever else holds the
    /// shared audio session lets go of it first. That is the wake mic, which
    /// DEACTIVATES the session when it stops - once its scorer has, some time
    /// after this session's first phase told it to. Landing after
    /// `audio.begin()`, that would switch the session off under the new mic.
    /// See `HeyAtlas.release`.
    @ObservationIgnored var beforeMic: (@MainActor @Sendable () async -> Void)?
    /// Checked after each turn: anything Claude proposed during it is read
    /// back and confirmed here, in place of the reply. nil when mail isn't
    /// wired in.
    @ObservationIgnored var mail: MailConfirming?
    /// The chimes and the thinking hum. nil plays nothing.
    @ObservationIgnored var cues: VoiceCues?
    /// Whether to keep listening after each answer, and what ends it. Read
    /// ONCE, at `trigger` - see `VoiceSettings`. Single-shot unless told:
    /// the app sets this from the user's settings (VoiceLive).
    @ObservationIgnored var settings: @MainActor () -> VoiceSettings = { VoiceSettings(continuous: false) }
    /// Seconds on a clock that only goes forward, for `SilenceWatch`. The seam
    /// for tests, which cannot wait 25 s a case.
    @ObservationIgnored var now: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// This session's settings, from `settings` at `trigger`.
    @ObservationIgnored private var conversation = VoiceSettings(continuous: false)
    /// The listening chime is playing: the phase says listening, but no
    /// listen is running yet for a press to finish.
    @ObservationIgnored private var chiming = false
    /// Send was pressed during the chime. The Transcriber forgets a finish
    /// that lands between listens, so this is where it is kept.
    @ObservationIgnored private var sentDuringChime = false

    @ObservationIgnored private let listener: Listening
    @ObservationIgnored private let speaker: Speaking
    @ObservationIgnored private let audio: VoiceAudio
    /// Who this session's question goes to, from `trigger` until it is over.
    /// Read by the pencil, which cancels only a session asking the chat it
    /// is leaving - see `ChatShell`.
    @ObservationIgnored private(set) var asking: Asking?
    /// A press landed while the answer was being read: listen again after.
    @ObservationIgnored private var bargeIn = false
    @ObservationIgnored private var cancelled = false
    /// Someone talked over the answer, and the listen that heard them is
    /// still running: what it returns is the next question, and nothing else
    /// may end it. See `readAloud`.
    @ObservationIgnored private var talkedOver = false
    /// The listen over the answer is finished with, or must not start: the
    /// reading ended with nobody talking over it. Read by `listenOver`, which
    /// may not have run yet when the reading ends.
    @ObservationIgnored private var doneListeningOver = false
    /// A listen over a reading is running right now, so there is something
    /// for `endListenOver` to end.
    @ObservationIgnored private var listeningOver = false
    /// What was heard over the answer, waiting to be asked. It stands in for
    /// the listen at the top of the next turn round the loop.
    @ObservationIgnored private var pending: String?
    /// Said once a session, not once an answer, when there is no listening
    /// over the answer to be done.
    @ObservationIgnored private var toldNoBargeIn = false
    /// The mic opening - `audio.begin()` - started by `trigger`, awaited by
    /// `loop` and by `micSettled`. nil when no session is running.
    @ObservationIgnored private var opening: Task<Void, any Error>?

    init(listener: Listening, speaker: Speaking, audio: VoiceAudio) {
        self.listener = listener
        self.speaker = speaker
        self.audio = audio
    }

    /// A press, a tap or "Hey Atlas". What it means depends on the phase:
    /// start when idle, send when listening, nothing while thinking (Cancel is
    /// for that), and cut in when an answer or a failure is being read.
    /// Cutting in listens again after a reply or a failed TURN; after the mic
    /// or a listen failed ("Mic busy.") it only stops the speech and ends.
    func trigger(_ asking: Asking) {
        guard phase.isIdle else { return press() }
        cancelled = false
        bargeIn = false
        pending = nil
        toldNoBargeIn = false
        conversation = settings()
        self.asking = asking
        // LISTENING IS PUBLISHED BEFORE THE MIC OPENS, deliberately. It is
        // what the wake word watches to let go of the mic (Task 16), and
        // what starts the Live Activity an AudioRecordingIntent must have
        // while recording. It is set HERE, not in `loop`, so the phase is
        // never `.idle` while a loop is queued but not yet running: a
        // second trigger in the same turn cannot start a second loop on
        // the one mic (it lands in `.listening` with no listen yet to
        // finish, so it is dropped), and a Cancel right after is not lost.
        phase = .listening(heard: "")
        let beforeMic = self.beforeMic
        let opening = Task {
            await beforeMic?()
            try await audio.begin()
        }
        self.opening = opening
        Task { await loop(asking, opening) }
    }

    /// Returns once the mic this session asked for is open, or has failed to
    /// open. At once when no session is running.
    ///
    /// `ListenIntent` WAITS ON THIS BEFORE IT RETURNS. The system's leave to
    /// start recording from the background comes with the intent, and nothing
    /// says it outlasts `perform`; opening the mic after `perform` returned
    /// would be betting that it does.
    func micSettled() async {
        _ = await opening?.result
    }

    /// A press on a session already running: `trigger`'s every case but the
    /// first, and the bar's Send/Talk button, which covers the composer's
    /// Talk. Nothing when idle - starting needs an `Asking`, so only
    /// `trigger` starts.
    func press() {
        switch phase {
        case .idle, .thinking:
            break
        case .listening:
            if chiming { sentDuringChime = true }
            listener.finish()
        case .speaking, .failed:
            bargeIn = true
            cues?.thinking(false)
            speaker.stop()
        }
    }

    /// Cancel, from the bar or the Live Activity. Stops whatever is happening,
    /// including the turn on the hub, and does not listen again.
    func cancel() {
        guard !phase.isIdle else { return }
        cancelled = true
        cues?.thinking(false)
        switch phase {
        case .listening: listener.cancel()
        case .thinking: asking?.cancel()
        case .speaking, .failed: speaker.stop()
        case .idle: break
        }
    }

    /// The audio session was interrupted - a phone call, an alarm, Siri.
    /// From `AudioSessionVoice.onInterrupted`, through VoiceLive.
    ///
    /// CANCEL, EXCEPT WHILE THINKING. A listen is cut off with nothing sent:
    /// the mic has stopped hearing, and the endpointer would otherwise send
    /// Atlas half a question. A reading is stopped, so `speak` returns rather
    /// than waiting on a synthesiser the call has cut off. But the turn Atlas
    /// is working on runs on: a call is no reason to throw that work away,
    /// the answer lands in the chat either way, and it is read when it
    /// arrives. The mic comes back when the interruption ends - see
    /// `AudioSessionVoice.restart`.
    func interrupted() {
        if case .thinking = phase { return }
        cancel()
    }

    private func loop(_ asking: Asking, _ opening: Task<Void, any Error>) async {
        do { try await opening.value } catch {
            await fail(Self.message(for: error))
            // AFTER THE FAILURE IS SAID, though `begin` has undone itself:
            // saying it switches the audio session back on, and in a process
            // that lives on, that session would go on ducking Spotify.
            audio.end()
            finish()
            return
        }
        // A CONVERSATION (`conversation.continuous`) goes round this loop
        // until an end phrase, a long silence, Cancel, a stopped turn or a
        // failed listen. Single-shot, it goes round only for a press or a
        // question heard over the answer, as it always has.
        var silence = SilenceWatch()
        var chime = true
        var ending: Ending?
        turns: repeat {
            bargeIn = false
            let started = now()
            let heard = await question(chime: chime)
            chime = true
            let text: String
            switch heard {
            case .words(let words):
                text = words
            case .failed:
                // SAID ALREADY, and final: a recogniser that failed once will
                // fail again, and a conversation would say so every 5 s.
                break turns
            case .nothing:
                guard conversation.continuous, !cancelled else { break turns }
                switch silence.heardNothing(listenStarted: started, now: now()) {
                case .listenAgain(let again):
                    chime = again
                    continue turns
                case .end:
                    ending = .silence
                    break turns
                }
            }
            silence.heardWords()
            // THE GOODBYE IS THE APP'S, never sent to Atlas. Only here, on a
            // question - which a goodbye at a read-back becomes: neither send
            // nor cancel, it cancels the proposal and comes round as the next
            // question (see `confirm`), and ends the conversation here.
            // LOGGED BY COUNT, NEVER BY CONTENT - see VoiceLog. The count and
            // the decision are what a device run needs to show why a question
            // reached Atlas, or why a goodbye did not end the conversation.
            let goodbye = EndPhrase.matches(text, phrases: conversation.endPhrases)
            Logger.voice.notice(
                "Voice: heard \(BargeIn.words(text).count, privacy: .public) words - \(goodbye ? "an end phrase, ending the conversation" : "asking", privacy: .public)"
            )
            if goodbye {
                ending = .phrase
                break turns
            }
            phase = .thinking(tool: nil)
            cues?.thinking(true)
            let result = await asking.ask(text) { [weak self] tool in
                // Only while thinking, for the reason in `hear`.
                guard let self, case .thinking = self.phase else { return }
                self.phase = .thinking(tool: tool)
            }
            if cancelled { break }
            switch result {
            case .reply(let markdown):
                // A TURN THAT PROPOSED SOMETHING IS ANSWERED BY ITS READ-BACK,
                // not by Atlas's reply: "Your message to Alex says: … Send it?"
                // is the whole answer, as it is with Siri. The reply ("It's
                // waiting for your OK") stays in the chat, for the screen.
                if let p = await proposal() {
                    pending = await confirm(p)
                } else {
                    // THE HUM PLAYS ON INTO `.speaking`, until the voice's first
                    // audio stops it (`VoiceOutput.schedule`): Kokoro can take a
                    // second to answer, and that second is thinking too.
                    let spoken = SpokenText.from(markdown)
                    phase = .speaking(spoken)
                    pending = await readAloud(spoken, own: false)
                    // A reading that never made a sound left it on.
                    cues?.thinking(false)
                }
            case .failed(let message):
                cues?.thinking(false)
                // A failed TURN is talked over like a reply: the mic is fine,
                // so whoever cuts in is asking again - as a press there does.
                pending = await fail(message, over: true)
            case .stopped:
                // The pencil: that chat is done with, and so is this.
                break turns
            }
        } while !cancelled && (conversation.continuous || bargeIn || pending != nil)
        if let ending, !cancelled { await end(ending) }
        audio.end()
        finish()
    }

    /// How a conversation ended by itself, rather than by Cancel.
    private enum Ending { case phrase, silence }

    /// The goodbye. A silence is SAID as well as chimed: nobody was talking,
    /// so nobody may be looking either. An end phrase is only chimed - the
    /// user just said goodbye, and knows.
    private func end(_ ending: Ending) async {
        cues?.thinking(false)
        if ending == .silence {
            phase = .speaking(Self.endingForSilence)
            _ = await readAloud(Self.endingForSilence, own: true, over: false)
        }
        guard !cancelled else { return }
        await cues?.play(.ending)
    }

    /// What one listen came to.
    private enum Heard {
        case words(String)
        /// Nothing said, or the listen was cancelled.
        case nothing
        /// The listen failed, and that has been said aloud.
        case failed

        var text: String? {
            if case .words(let text) = self { text } else { nil }
        }
    }

    /// The next question: what was heard over the answer, if anything was,
    /// and otherwise a fresh listen - chimed first when `chime`.
    private func question(chime: Bool) async -> Heard {
        if let pending {
            self.pending = nil
            return cancelled ? .nothing : .words(pending)
        }
        phase = .listening(heard: "")
        return await hear(chime: chime)
    }

    /// One listen, and a failure has been read aloud by the time this
    /// returns, unless the session was cancelled (see `fail`).
    ///
    /// THE HUM IS OFF AND THE CHIME OVER BEFORE THE MIC IS ROUTED to the
    /// recogniser: `play` returns once the chime has been heard, so the
    /// listen never transcribes the app's own sounds. Echo cancellation
    /// would take most of them out anyway; this does not rely on it.
    private func hear(chime: Bool = true) async -> Heard {
        cues?.thinking(false)
        // A Cancel that landed while the mic was opening. Without this the
        // listen would run on to the no-speech timeout.
        guard !cancelled else { return .nothing }
        if chime, let cues {
            chiming = true
            sentDuringChime = false
            await cues.play(.listening)
            chiming = false
            guard !cancelled else { return .nothing }
            // SEND BEFORE ANYTHING WAS SAID: as a press on an empty listen.
            if sentDuringChime { return .nothing }
        }
        do {
            let heard = try await listener.listen { [weak self] words in
                // ONLY WHILE LISTENING. The real listener reports through a hop
                // to the main actor that is not ordered with its return, so
                // words can land after the listen is over. Set blindly, they
                // would put a finished session back in `.listening` with no
                // loop behind it, and every press after would be swallowed.
                guard let self, case .listening = self.phase else { return }
                self.phase = .listening(heard: words)
            }
            guard !cancelled else { return .nothing }
            return Self.question(from: heard).map(Heard.words) ?? .nothing
        } catch {
            await fail(Self.message(for: error))
            return .failed
        }
    }

    /// What this turn proposed and is waiting on the phone for, if anything.
    /// Fetched while the hum still plays: it is a round trip to the hub.
    private func proposal() async -> Approval? {
        guard let mail, !cancelled else { return nil }
        guard let p = await mail.nextUnvoiced() else {
            Logger.voice.notice("Voice: nothing pending to read back")
            return nil
        }
        return cancelled ? nil : p
    }

    /// Siri-style confirmation for what Claude just proposed: an email, a
    /// text, a calendar change.
    ///
    /// The read-back is the app's own sentence built from what mailgate hashed
    /// (Approval.readBack), NEVER Claude's reply. It is read with listening
    /// OFF (`over: false`), so Atlas's own voice saying "send" can't be heard
    /// as the user. Only after it finishes does the mic listen, once, and only
    /// a strict "send" (see SpokenConfirm) approves.
    ///
    /// `own: true` IS LOAD-BEARING: the app's own words go to the on-device
    /// Apple voice (FallbackVoice.say), never to Kokoro via the hub, so atlas
    /// can't make the phone SAY one message while the card and hash are another.
    ///
    /// Returns the next question when the answer was neither send nor cancel
    /// but words - "make it say hi instead", "change it", "add a please". THE
    /// PROPOSAL IS CANCELLED FIRST, so a text the user turned away from cannot
    /// go out on a stray tap while they talk about the next one; then the
    /// words go to Atlas, which proposes again or asks what it should say, and
    /// that is read back in turn. Silence leaves it on the card.
    private func confirm(_ p: Approval) async -> String? {
        guard let mail else { return nil }
        Logger.voice.notice("Voice: reading back a pending \(p.noun, privacy: .public)")
        phase = .speaking(p.readBack)
        _ = await readAloud(p.readBack, own: true, over: false)
        // A read-back that never made a sound left the hum on.
        cues?.thinking(false)
        guard !cancelled else { return nil }
        phase = .listening(heard: "")
        let heard = await hear().text
        guard !cancelled else { return nil }
        let answer = SpokenConfirm.parse(heard)
        Logger.voice.notice(
            "Voice: heard \(BargeIn.words(heard ?? "").count, privacy: .public) words after the read-back - \(answer.map { $0 == .send ? "send" : "cancel" } ?? (heard == nil ? "nothing" : "a change"), privacy: .public)"
        )
        let result: String
        switch answer {
        case .send: result = await mail.approve(p)
        case .cancel: result = await mail.cancel(p)
        case nil:
            if let heard {
                _ = await mail.cancel(p)
                return heard
            }
            result = "Left it on screen. Tap Send when you're ready."
        }
        phase = .speaking(result)
        _ = await readAloud(result, own: true, over: false)
        return nil
    }

    /// What a listen heard, as a question: nothing is nothing.
    private static func question(from heard: String?) -> String? {
        let text = heard?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// Reads `text` aloud, and listens over it so that Atlas can be talked
    /// over. Returns the question heard over it, if there was one.
    ///
    /// ONE STEP, TWO THINGS AT ONCE. The listen is an `async let` this step
    /// owns, so it cannot outlive the reading it belongs to and nothing else
    /// can start a second one. Talked over, the reading is stopped and the
    /// SAME listen runs on to its natural end - the endpointer's pause - so
    /// the words that cut Atlas off and the words after them are one
    /// question, not two halves of one.
    ///
    /// ONLY WITH ECHO CANCELLATION. Without it the mic hears the answer
    /// itself, and Atlas would talk itself to a stop - see `BargeIn`.
    private func readAloud(_ text: String, own: Bool, over listening: Bool = true) async -> String? {
        guard listening, audio.echoCancelled else {
            if listening, !toldNoBargeIn {
                toldNoBargeIn = true
                Logger.voice.notice("Voice: no echo cancellation, so the answer cannot be talked over")
            }
            await read(text, own: own)
            return nil
        }
        talkedOver = false
        doneListeningOver = false
        async let heard = listenOver()
        await read(text, own: own)
        // THE READING ENDED FIRST - it was read out, or a press or Cancel
        // stopped it - so the listen over it is finished with. Talked over,
        // it is left running: what it returns is the next question.
        if !talkedOver { endListenOver() }
        return Self.question(from: await heard)
    }

    /// `say` for the app's own words, `speak` for an answer - see
    /// `Speaking.say`.
    private func read(_ text: String, own: Bool) async {
        if own { await speaker.say(text) } else { await speaker.speak(text) }
    }

    /// The patient listen held open over a reading.
    private func listenOver() async -> String? {
        // THE READING MAY ALREADY BE OVER. This runs at the reading's first
        // suspension, and a reading that never suspends (a speaker with
        // nothing to fetch) is finished before then. Listening now would
        // leave a listen with nobody to end it.
        guard !doneListeningOver else { return nil }
        listeningOver = true
        defer { listeningOver = false }
        do {
            return try await listener.listen(patient: true) { [weak self] words in
                self?.overheard(words)
            }
        } catch {
            // NOT SAID ALOUD, unlike a listen for a question that fails: the
            // answer is being read, and "Mic busy." over the top of it would
            // be worse than losing the chance to talk over this one.
            Logger.voice.error("Voice: the listen over the reading failed with \(error.domainAndCode, privacy: .public)")
            return nil
        }
    }

    /// Ends the listen over a reading, if one is running: the reading may
    /// have finished before `listenOver` ever ran, and then there is nothing
    /// to cancel - only the flag that stops it starting. The listener is
    /// never cancelled between listens, where that would be either nothing
    /// or, worse, the next listen's business.
    private func endListenOver() {
        doneListeningOver = true
        guard listeningOver else { return }
        listeningOver = false
        listener.cancel()
    }

    /// The transcript of the listen held over a reading, as it grows: Atlas
    /// coming back through the speaker until two words say it is not.
    private func overheard(_ words: String) {
        guard !talkedOver else {
            // Already cut in, so this is the question being asked. Only while
            // listening, for the reason in `hear`.
            guard case .listening = phase else { return }
            phase = .listening(heard: words)
            return
        }
        guard !doneListeningOver, !cancelled else { return }
        switch phase {
        case .speaking, .failed: break
        default: return
        }
        // ASKED AGAIN HERE, not only when the listen started: the mic restarts
        // on a route change mid-answer, and comes back WITHOUT voice
        // processing once it has restarted too often - see `AudioSessionVoice`.
        // What the mic hears then may be Atlas itself.
        guard audio.echoCancelled,
            BargeIn.isUser(heard: words, speaking: speaker.speakingNow)
        else { return }
        talkedOver = true
        cues?.thinking(false)
        Logger.voice.notice("Voice: talked over - the reading stops, and the listen carries on as the question")
        speaker.stop()
        phase = .listening(heard: words)
    }

    /// SAID, NOT ONLY SHOWN. From the lock screen there is nothing to read.
    /// Except after Cancel: a mic or a listen that fails on its way down would
    /// otherwise say "Mic busy." to someone who just asked for quiet.
    ///
    /// `over` is whether it can be talked over: a failed TURN can, exactly as
    /// a press cuts into one, while "Mic busy." cannot - the mic is the thing
    /// that just failed, and there is nothing to listen with.
    @discardableResult
    private func fail(_ message: String, over listening: Bool = false) async -> String? {
        guard !cancelled else { return nil }
        phase = .failed(message)
        return await readAloud(message, own: true, over: listening)
    }

    private func finish() {
        cues?.thinking(false)
        asking = nil
        opening = nil
        phase = .idle
    }
}
