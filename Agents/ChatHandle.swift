import Foundation

/// The one seam between the shell's top bar and the chat underneath it.
///
/// THE PENCIL IS IN THE SHELL AND THE TURN IS IN THE CHAT, with no reference
/// between them: `ClaudeView` builds its own `ChatModel` into `@State` - or,
/// for the voice chat, is handed the one `AtlasVoice` owns - and `ChatShell`
/// only ever hands it a `ChatTarget` value and rebuilds it through `.id()`.
/// That indirection is deliberate and worth keeping - it is what makes
/// "switch agent" and "open a thread" the same one line of code - but it leaves
/// the shell able to say nothing to the chat except "become a different chat".
/// Cancelling is exactly the thing that cannot be said that way: it has to
/// reach the OLD model, before the new target throws it away.
///
/// So: ONE EXPLICIT HANDLE, owned by the shell, that the on-screen chat
/// registers itself with. Not a closure box, not a notification, and not the
/// obvious-looking alternative of lifting `ChatModel` up into the shell - that
/// last one means keeping the model and the target in step by hand, in two
/// places, where today `.id(target)` does it structurally and cannot drift.
/// A named door with one verb behind it keeps the shell able to do the single
/// thing it is allowed to do to a chat it does not own.
///
/// ONE SLOT, because exactly one chat is ever on screen.
@MainActor
final class ChatHandle {
    /// WEAK, and the direction of ownership is the reason. `ClaudeView`'s
    /// `@State` owns the model for as long as that view keeps its identity -
    /// with `AtlasVoice` as a second owner of the voice chat's, whose turns
    /// run with no view at all. This is a way to REACH the current one, never
    /// an owner of it.
    ///
    /// A running turn retains its own model anyway - `run` is a method, so the
    /// `Task` captures `self` - which is precisely why a deliberately abandoned
    /// turn still finishes into its own, now off-screen, model. That is the
    /// behaviour `hub/turns.js` is built around, and it is also why weakness
    /// costs nothing here: by the time such a model is freed, this handle has
    /// long since been pointed at the new one.
    private weak var chat: ChatModel?

    /// Called by the chat itself, ON APPEAR.
    ///
    /// NOT FROM `ClaudeView.init`, which is the obvious place and is wrong.
    /// That initialiser runs on every body evaluation of the shell and builds a
    /// throwaway `ChatModel` each time, all but the first discarded unseen by
    /// `State(initialValue:)`. Registering there points this handle at a model
    /// that is not on screen and will never run a turn - and the failure is
    /// silent in the worst way: the pencil goes on working, cancelling nothing,
    /// forever.
    ///
    /// AND THERE IS DELIBERATELY NO `deregister`. Pairing this with an
    /// `.onDisappear` is the obvious symmetry and it is a bug: SwiftUI appears
    /// the incoming view before it disappears the outgoing one, so the old
    /// chat's teardown would clear a registration the new chat had already
    /// made, and the pencil would cancel nothing for the rest of that chat's
    /// life. Nothing needs clearing anyway - the reference is weak, and the
    /// next chat to appear overwrites it.
    func register(_ chat: ChatModel) { self.chat = chat }

    /// Stops the turn the on-screen chat has in flight, if it has one.
    func cancelLiveTurn() { chat?.cancelLiveTurn() }

    /// Whether `model` is the chat on screen - so the shell does not rebuild a
    /// chat that is already showing, scrolling it back to the top mid-answer.
    func isShowing(_ model: ChatModel?) -> Bool { model != nil && chat === model }

    /// Whether `asking` - a voice session's - is putting its question to the
    /// chat on screen. That is the composer mic, which asks through a
    /// `ChatModelTurn` on the model it sits under. `AtlasVoice` asks its own
    /// model, and the shell decides about that one from the target.
    func isAsked(by asking: Asking?) -> Bool {
        guard let turn = asking as? ChatModelTurn else { return false }
        return isShowing(turn.model)
    }
}
