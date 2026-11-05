import Foundation

/// The three fields `HubClient.transcript` needs to fetch one thread.
///
/// A STRUCT, NOT THE TUPLE THIS USED TO BE, and the reason is load-bearing
/// rather than stylistic: `ChatTarget` below must be `Hashable` so the shell
/// can drive `.id()` with it, and **a Swift tuple cannot conform to a
/// protocol**. A `ChatTarget` holding the old
/// `(source: String, node: String, id: String)?` does not compile, and the
/// error points at the target rather than at the tuple.
struct ResumeRef: Hashable, Sendable {
    let source: String
    let node: String
    let id: String
}

/// IN AN EXTENSION, NOT IN THE BODY ABOVE, and that is load-bearing too rather
/// than a layout preference: an `init` declared inside the struct suppresses
/// Swift's synthesized memberwise init, and `ResumeRef(source:node:id:)` is
/// what the tests construct with today and what `ChatTarget.resuming` builds in
/// Task 4. Folding this back into the body as a tidy-up breaks compilation at
/// both of those call sites, not here.
extension ResumeRef {
    /// Only the three fields the transcript endpoint addresses by travel here -
    /// not the whole `Conversation`, whose title and timestamp are the shell's
    /// business rather than the fetch's.
    init(_ c: Conversation) {
        self.init(source: c.source, node: c.node, id: c.id)
    }
}

/// One row in the agent picker.
///
/// THE MACHINE IS THE IDENTITY AND THE AGENT KIND IS THE SUBTITLE, because
/// "Hermes" is both a machine name and an agent kind and those are not the same
/// fact. The conversation list has always split them for this reason - see the
/// machine badge on a `HistoryDrawer` row - and this keeps the split rather than
/// inventing a third vocabulary.
struct AgentChoice: Identifiable, Hashable, Sendable {
    let agent: Agent
    /// What the picker shows. Capitalised - this is a label, not a key.
    let machine: String
    /// What runs on it, shown under the machine name.
    let kind: String

    /// THE WHOLE VALUE, not `machine`. A machine name is not unique across every
    /// `AgentChoice` that can exist: `forConversation` builds one below for a
    /// box outside the table, and a `Conversation(source: "claude", node:
    /// "hermes")` yields a choice whose machine is "Hermes" while comparing
    /// unequal to `all[1]` under the synthesized `Hashable`. A `String`-keyed id
    /// was therefore strictly weaker than equality - two different choices
    /// sharing one id - which SwiftUI resolves by silently dropping a row the
    /// moment a built choice is listed alongside `all`. `Self` is legal here
    /// precisely because the type is already `Hashable`.
    var id: Self { self }

    /// Rack order, not alphabetical - the order these sit in the rack and the
    /// order they appear everywhere else in the app.
    static let all: [AgentChoice] = [
        .init(agent: .claude, machine: "Atlas", kind: "Claude Code"),
        .init(agent: .hermes(node: "hermes"), machine: "Hermes", kind: "Hermes agent"),
        .init(agent: .hermes(node: "calypso"), machine: "Calypso", kind: "Hermes agent"),
    ]

    /// Atlas, because it is the only box running Claude Code. This is what the
    /// app opens on.
    static let fallback = all[0]

    /// The hub's node name for this choice. Lowercase, because it is a key the
    /// hub sends rather than a label a person reads.
    ///
    /// THE HARDCODED "atlas" IS A PROTOCOL FACT, NOT A TABLE ENTRY. `SSEStream`
    /// sends `node` only for `.hermes` (`if case .hermes(let node) = agent`), so
    /// `/api/claude` carries no node on the wire at all - Claude is atlas-only
    /// in the request shape, not merely in `all` above. This line is valid only
    /// while `Agent.claude` has no associated node; a second Claude box needs
    /// the hub and that enum case to change first, and relaxing this alone would
    /// just mislabel threads that all still route to the one atlas endpoint.
    var node: String {
        switch agent {
        case .claude: "atlas"
        case .hermes(let n): n
        }
    }

    /// The hub's `source` for this choice - which of the two agent kinds it is.
    var sourceKey: String {
        switch agent {
        case .claude: "claude"
        case .hermes: "hermes"
        }
    }

    /// Which choice a history row belongs to.
    ///
    /// MATCHED ON SOURCE **AND** NODE, not node alone. They cannot currently
    /// disagree, and matching on one of them would be a silent wrong answer the
    /// day they can.
    static func forConversation(_ c: Conversation) -> AgentChoice {
        if let known = all.first(where: { $0.node == c.node && $0.sourceKey == c.source }) {
            return known
        }
        // A node not in the table - a fourth agent box. Build a choice FOR IT
        // rather than falling back to Atlas: resuming a calypso-shaped thread
        // against /api/claude is a 404 the user sees as "this conversation
        // didn't load", with nothing pointing at the real cause.
        return AgentChoice(
            agent: c.source == "claude" ? .claude : .hermes(node: c.node),
            machine: c.node.capitalized,
            kind: c.source.capitalized)
    }
}

/// What the shell is currently showing: which agent, under what title, resuming
/// what (if anything).
///
/// THE SHELL RENDERS `ClaudeView(...).id(target)`, so replacing this value is
/// what tears the chat down and builds a new one with a fresh `ChatModel`. One
/// mechanism covers both "switch agent" and "open a thread from history", which
/// is why `ClaudeView` needs no retarget method and `ChatModel` needs no
/// mutation path.
///
/// THE TARGET MUST BE READ FROM `@State` STORAGE AND NEVER BUILT INLINE, and
/// this is the one way to hold the type wrong. `generation` below makes every
/// minted `ChatTarget` a new identity, which is exactly what is wanted when the
/// shell ASSIGNS a new target and exactly what ruins it if a target is DERIVED
/// per render: an inline `.id(ChatTarget.fresh(choice))`, a computed
/// `var target: ChatTarget { .fresh(choice) }`, or an id built inside a
/// `ForEach` body hands `.id()` a different value on every pass, so SwiftUI
/// tears `ClaudeView` down and rebuilds it on every render and the `ChatModel`
/// is discarded mid-stream. The chat then simply never finishes a reply, with
/// no error anywhere - it is silent and continuous rather than a crash. Stored
/// in `@State` and assigned only on a deliberate switch, the same value comes
/// back each render and nothing rebuilds.
struct ChatTarget: Hashable, Sendable {
    let choice: AgentChoice
    let title: String
    let resume: ResumeRef?
    /// The voice chat, whose `ChatModel` already exists - `AtlasVoice` built it,
    /// often with the app in the background. The shell hands that model in
    /// rather than building a fresh one; see `ChatShell.chat`.
    let isVoice: Bool

    /// MAKES TWO OTHERWISE-IDENTICAL TARGETS DIFFERENT, and it is not
    /// decoration. Without it `fresh(atlas)` equals `fresh(atlas)`, so tapping
    /// New Chat while already on Atlas produces an equal value, `.id()` does
    /// not rebuild, and the half-finished thread you wanted to leave is still
    /// on screen. The same applies to re-tapping a history row.
    private let generation: UUID

    /// Private so the factories below are the only way to mint one - a
    /// memberwise init would let a call site reuse a generation and quietly
    /// reintroduce exactly the bug it exists to prevent.
    private init(choice: AgentChoice, title: String, resume: ResumeRef?, isVoice: Bool = false) {
        self.choice = choice
        self.title = title
        self.resume = resume
        self.isVoice = isVoice
        self.generation = UUID()
    }

    var agent: Agent { choice.agent }

    /// A new, empty chat with one agent. The title is the machine name, so the
    /// composer reads "Ask Atlas".
    static func fresh(_ choice: AgentChoice) -> ChatTarget {
        ChatTarget(choice: choice, title: choice.machine, resume: nil)
    }

    /// The thread behind a history row.
    static func resuming(_ c: Conversation) -> ChatTarget {
        ChatTarget(choice: .forConversation(c), title: c.title, resume: ResumeRef(c))
    }

    /// The voice chat, brought on screen when a spoken question arrives while
    /// the app is open.
    static func voice() -> ChatTarget {
        ChatTarget(choice: .fallback, title: AgentChoice.fallback.machine, resume: nil, isVoice: true)
    }
}
