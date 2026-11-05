// Agents/Voice/VoiceThread.swift
import Foundation

/// Which chat a question from the Action Button, the control or the wake word
/// goes into.
///
/// CONTINUE IF RECENT - the user's call, 2026-09-21. A follow-up like "and
/// calypso?" said within ten minutes lands in the same thread, with its
/// context; anything later starts clean, so tomorrow's question does not drag
/// in today's. PERSISTED, not held in memory, because a press on a locked
/// phone often launches the app cold.
struct VoiceThread: Equatable {
    static let window: TimeInterval = 10 * 60

    let conversation: String
    let lastUsed: Date

    /// The thread to continue at `now`, or nil for a new one. A clock that
    /// stepped backwards (NTP, a time-zone change, a manual set) is treated
    /// as NOT recent, never as always-recent.
    static func reusable(_ stored: VoiceThread?, at now: Date) -> String? {
        guard let stored, isRecent(stored.lastUsed, at: now) else { return nil }
        return stored.conversation
    }

    private static func isRecent(_ used: Date, at now: Date) -> Bool {
        now >= used && now.timeIntervalSince(used) < window
    }

    /// Where the next voice question goes.
    enum Choice: Equatable {
        /// The voice chat's model already in memory.
        case reuse
        /// A new model, re-opening this saved thread by id - the app was
        /// relaunched inside the ten minutes.
        case reopen(String)
        /// A new model on a new thread.
        case new
    }

    /// `AtlasVoice.modelForNow`'s decision, from the saved thread and the
    /// voice chat's model in memory, if there is one.
    ///
    /// THE MODEL IN MEMORY DECIDES WHEN THERE IS ONE, and the saved thread only
    /// when there is not. Typing or the composer mic in the voice chat is use
    /// too, but it runs through the model, never `AtlasVoice`, so it saves
    /// nothing - the model's own `lastTurnEnded` is the only record of it. And
    /// the saved thread only ever describes that same model, a little later:
    /// if the model has lost its thread, the saved id is dead as well.
    ///
    /// BUSY IS REUSED HOWEVER OLD. The question then fails "Still answering."
    /// in the chat that is answering, rather than starting a new thread and
    /// pulling the screen off the answer being written.
    static func choose(
        saved: VoiceThread?,
        inMemory: (threadId: String?, lastTurnEnded: Date?, busy: Bool)?,
        at now: Date
    ) -> Choice {
        if let inMemory {
            if inMemory.busy { return .reuse }
            if inMemory.threadId != nil, let ended = inMemory.lastTurnEnded,
                isRecent(ended, at: now)
            {
                return .reuse
            }
            return .new
        }
        return reusable(saved, at: now).map { .reopen($0) } ?? .new
    }

    private static let idKey = "voice.conversation"
    private static let usedKey = "voice.lastUsed"

    static func load(from defaults: UserDefaults = .standard) -> VoiceThread? {
        guard let id = defaults.string(forKey: idKey),
            let used = defaults.object(forKey: usedKey) as? Date
        else { return nil }
        return VoiceThread(conversation: id, lastUsed: used)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(conversation, forKey: Self.idKey)
        defaults.set(lastUsed, forKey: Self.usedKey)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: idKey)
        defaults.removeObject(forKey: usedKey)
    }
}
