// Agents/Voice/AtlasVoice.swift
import Foundation

/// The voice chat: where every question goes that did not start at the
/// composer mic - the Action Button, the control, Back Tap, "Hey Atlas".
///
/// OWNS ITS `ChatModel`, unlike every other chat in the app, whose model lives
/// in its view's `@State`. These turns start on a locked phone with no view to
/// own anything, and the model has to survive until the shell shows it.
@Observable @MainActor
final class AtlasVoice: Asking {
    static let shared = AtlasVoice()

    private(set) var model: ChatModel?
    /// Counts questions asked. `ChatShell` watches it to bring the voice chat
    /// on screen when one arrives while the app is open.
    private(set) var asked = 0
    /// True while a question is with Atlas. Separates "a voice session is
    /// running" from "a voice session is running IN THE VOICE CHAT" - the
    /// composer mic runs sessions too, in whatever chat is on screen.
    private(set) var answering = false

    func ask(_ text: String, onTool: @escaping @MainActor @Sendable (String) -> Void) async -> AskResult {
        let model = modelForNow()
        asked += 1
        answering = true
        // SAVED THE MOMENT THE HUB NAMES THE THREAD, as well as below. A turn
        // can run for minutes, and an app killed in them would have saved
        // nothing: the follow-up would start a new thread. Only while this
        // ask runs - typing in the voice chat saves nothing, see
        // `VoiceThread.choose` - and not once the pencil has forgotten the
        // model, for the reason below.
        model.onThread = { [weak self, weak model] id in
            guard let self, let model, self.model === model else { return }
            VoiceThread(conversation: id, lastUsed: .now).save()
        }
        defer {
            answering = false
            model.onThread = nil
        }
        let result = await ChatModelTurn(model).ask(text, onTool: onTool)
        // FORGOTTEN WHILE IT RAN - the pencil on the voice chat, which cancels
        // this turn and then calls `forget`. The tail of that cancelled turn
        // lands here afterwards and would save the thread straight back.
        guard self.model === model else { return result }
        // SAVED AFTER EVERY TURN, CLEARED WHEN THERE IS NO THREAD. `threadId`
        // is nil when the hub said the thread is gone, or when the turn failed
        // before the hub named one; either way the next question starts clean
        // rather than retrying a dead id for the rest of the ten minutes.
        if let id = model.threadId {
            VoiceThread(conversation: id, lastUsed: .now).save()
        } else {
            VoiceThread.clear()
        }
        return result
    }

    func cancel() { model?.stop() }

    /// The pencil on the voice chat: done with this thread, so the next
    /// question starts a new one rather than continuing it for ten minutes.
    func forget() {
        VoiceThread.clear()
        model = nil
    }

    /// The same model while the thread is still current - so the shell keeps
    /// showing one growing chat - or a new one, re-opening the saved thread by
    /// id if the app was relaunched inside the ten minutes. The rule is
    /// `VoiceThread.choose`.
    private func modelForNow() -> ChatModel {
        let choice = VoiceThread.choose(
            saved: VoiceThread.load(),
            inMemory: model.map { (threadId: $0.threadId, lastTurnEnded: $0.lastTurnEnded, busy: $0.busy) },
            at: .now)
        if case .reuse = choice, let model { return model }
        let reopen: Attach = if case .reopen(let id) = choice { .conversation(id) } else { .none }
        let fresh = ChatModel(agent: .claude, title: AgentChoice.fallback.machine, attach: reopen)
        model = fresh
        return fresh
    }
}
