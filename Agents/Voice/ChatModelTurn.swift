// Agents/Voice/ChatModelTurn.swift
import Foundation

/// A voice question asked through an existing chat, exactly as if it had been
/// typed there: the words land as your bubble, the answer streams in, and
/// re-attaching, cancelling and errors are all `ChatModel`'s, unchanged.
@MainActor
final class ChatModelTurn: Asking {
    let model: ChatModel

    init(_ model: ChatModel) { self.model = model }

    func ask(_ text: String, onTool: @escaping @MainActor @Sendable (String) -> Void) async -> AskResult {
        // BUSY IS CHECKED BEFORE `onTool` IS TOUCHED. A refused ask that set
        // it first would clear it on the way out - the running ask's hook.
        guard !model.busy else { return .failed(ClaudeError.busy.localizedDescription) }
        let from = model.bubbles.count
        model.onTool = onTool
        defer { model.onTool = nil }
        // Not busy, so the only refusal left is blank words.
        guard await model.ask(text) else { return .failed(AskResult.noAnswer) }
        // The model's flag, not the bubbles': a Stop during a tool run has no
        // reply bubble to mark, and `from` would read it as "no answer".
        if model.stopped { return .stopped }
        return .from(model.bubbles.dropFirst(from))
    }

    func cancel() { model.stop() }
}

extension AskResult {
    static let noAnswer = "No answer came back."
    static let dropped = "The connection dropped. What came through is in the chat."

    /// How a finished turn ended, from the bubbles it added.
    ///
    /// THE ANSWER IS THE TEXT AFTER THE LAST TOOL, and nothing else. A Claude
    /// Code turn is text, tool, text, tool, text; the texts before a tool are
    /// "let me check", and read aloud ahead of a failure "I'll restart it."
    /// sounds like success. So a turn that dies after a tool speaks its error.
    /// A denied tool still gets an answer, because Claude writes text after
    /// it. An answer outranks a trailing error - a permission denial after
    /// "Done." is detail for the screen, not for the ear - but only a WHOLE
    /// answer: an `incomplete` one read aloud sounds like all of it.
    static func from(_ added: ArraySlice<Bubble>) -> AskResult {
        if added.contains(where: { $0.kind == .assistant && $0.stopped }) { return .stopped }
        let afterTools = added.lastIndex(where: { $0.kind == .tool }).map { added[($0 + 1)...] } ?? added
        if let answer = afterTools.last(where: { $0.kind == .assistant }),
            !answer.incomplete, !answer.text.isEmpty
        {
            return .reply(answer.text)
        }
        if let error = added.last(where: { $0.kind == .error }) { return .failed(error.text) }
        if added.contains(where: { $0.kind == .assistant && $0.incomplete }) { return .failed(dropped) }
        return .failed(noAnswer)
    }
}
