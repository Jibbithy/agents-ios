import Foundation

/// One row of GET /api/conversations.
struct Conversation: Codable, Identifiable, Sendable {
    let id: String
    let source: String  // "claude" | "hermes"
    let node: String  // "atlas" | "hermes" | "calypso"
    let title: String
    let updatedAt: Double  // epoch MILLISECONDS
    let count: Int?  // null for Claude - counting its messages would
    // mean reading every transcript on every list

    /// Distinct across sources: two agents' id namespaces are unrelated, and
    /// the hub addresses a transcript by all three.
    var key: String { "\(source)/\(node)/\(id)" }
}

/// A source that could not be reached. The list still returns 200 with the
/// sources that worked, so this is a note beside the rows, never a failure.
struct ConversationError: Codable, Sendable, Identifiable {
    let source: String
    let node: String
    let error: String
    let code: String?
    var id: String { "\(source)/\(node)" }
}

struct ConversationsPage: Codable, Sendable {
    let conversations: [Conversation]
    let errors: [ConversationError]
}

/// NOT `Identifiable`. `load(transcript:)` maps these into `Bubble`s, which
/// carry their own `UUID`, so nothing here needs a synthesized id - and a
/// `"\(role)-\(ts ?? 0)-\(text.prefix(24))"` one used to exist that two
/// identical short messages with a null `ts` would collide on. Add id-based
/// identity back only if a future caller actually iterates these directly,
/// and make it index-based rather than content-based if so.
struct TranscriptMessage: Codable, Sendable {
    let role: String  // "user" | "assistant"
    let text: String
    let ts: Double?  // epoch ms, and genuinely nullable - the hub
    // writes null when a transcript line's own
    // timestamp fails to parse (see claudelog.js's
    // parseTranscript), not just for old data.
}

struct Transcript: Codable, Sendable {
    let source: String
    let node: String
    let id: String
    let messages: [TranscriptMessage]
}
