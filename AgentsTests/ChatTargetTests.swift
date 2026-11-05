// AgentsTests/ChatTargetTests.swift
import XCTest

@testable import Agents

final class ResumeRefTests: XCTestCase {
    /// The three fields HubClient.transcript addresses a thread by. They are a
    /// struct rather than the tuple this used to be for one hard reason: a
    /// tuple cannot conform to Hashable, and ChatTarget must.
    ///
    /// All three fields are varied one at a time, and the `node`-only pair is
    /// the one that earns its keep: the two Hermes boxes mint ids from the same
    /// `api_<ms>_<rand>` scheme, so two live threads can genuinely share an `id`
    /// and a `source` and differ ONLY by which box they are on. An `==` that
    /// ignored `node` would satisfy every other assertion here while collapsing
    /// those two into one - the exact collision `Conversation.key` exists to
    /// prevent.
    func testResumeRefIsHashable() {
        let a = ResumeRef(source: "claude", node: "atlas", id: "abc")
        let b = ResumeRef(source: "claude", node: "atlas", id: "abc")
        let differentSource = ResumeRef(source: "hermes", node: "atlas", id: "abc")
        let differentNode = ResumeRef(source: "claude", node: "calypso", id: "abc")
        let differentId = ResumeRef(source: "claude", node: "atlas", id: "xyz")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, differentSource)
        XCTAssertNotEqual(a, differentNode)
        XCTAssertNotEqual(a, differentId)
        XCTAssertEqual(Set([a, b, differentSource, differentNode, differentId]).count, 4)
    }

    func testResumeRefIsBuiltFromAConversation() {
        let conv = Conversation(
            id: "abc", source: "hermes", node: "calypso",
            title: "a thread", updatedAt: 1_700_000_000_000, count: 4)
        XCTAssertEqual(
            ResumeRef(conv),
            ResumeRef(source: "hermes", node: "calypso", id: "abc"))
    }

    /// `ResumeRef` and `Conversation.key` are the same address in two shapes,
    /// and `HubClient.transcript` builds its URL as literally `source/node/id`.
    /// Nothing in the type system ties them together, so this asserts the tie:
    /// if a future edit reorders or drops a field on either side, the two stop
    /// naming the same thread and a resumed chat quietly fetches the wrong one.
    func testResumeRefSpellsTheSameAddressAsConversationKey() {
        let conv = Conversation(
            id: "api_1700000000000_x9q", source: "hermes",
            node: "calypso", title: "a thread",
            updatedAt: 1_700_000_000_000, count: 4)
        let ref = ResumeRef(conv)
        XCTAssertEqual("\(ref.source)/\(ref.node)/\(ref.id)", conv.key)
    }
}

final class AgentHashableTests: XCTestCase {
    /// Needed so ChatTarget can be Hashable. Two Hermes boxes are two
    /// DIFFERENT agents and must not collide, or switching between them would
    /// leave the chat on screen.
    func testAgentHashableSeparatesTheTwoHermesBoxes() {
        XCTAssertEqual(Agent.claude, Agent.claude)
        XCTAssertEqual(Agent.hermes(node: "hermes"), Agent.hermes(node: "hermes"))
        XCTAssertNotEqual(Agent.hermes(node: "hermes"), Agent.hermes(node: "calypso"))
        XCTAssertNotEqual(Agent.claude, Agent.hermes(node: "atlas"))
        XCTAssertEqual(
            Set([
                Agent.claude,
                .hermes(node: "hermes"),
                .hermes(node: "calypso"),
                .hermes(node: "hermes"),
            ]).count, 3)
    }
}

final class AgentChoiceTests: XCTestCase {
    func testTheThreeRowsInRackOrder() {
        XCTAssertEqual(AgentChoice.all.map(\.machine), ["Atlas", "Hermes", "Calypso"])
        XCTAssertEqual(
            AgentChoice.all.map(\.kind),
            ["Claude Code", "Hermes agent", "Hermes agent"])
        XCTAssertEqual(
            AgentChoice.all.map(\.agent),
            [.claude, .hermes(node: "hermes"), .hermes(node: "calypso")])
    }

    func testAtlasIsTheDefaultBecauseItIsTheOnlyBoxRunningClaude() {
        XCTAssertEqual(AgentChoice.fallback.machine, "Atlas")
        XCTAssertEqual(AgentChoice.fallback.agent, .claude)
    }

    func testNodeAndSourceKeyMatchTheHubsVocabulary() {
        XCTAssertEqual(AgentChoice.all.map(\.node), ["atlas", "hermes", "calypso"])
        XCTAssertEqual(AgentChoice.all.map(\.sourceKey), ["claude", "hermes", "hermes"])
    }

    /// Both halves matter. The `.machine` assertions say the row is the right
    /// one to a reader; the whole-value ones say it is the SAME VALUE as the
    /// table entry, which is what the shell actually relies on - the agent menu
    /// guards with `choice != target.choice`, comparing whole choices rather
    /// than machine names. A known branch rewritten to construct a fresh
    /// `AgentChoice` instead of returning the table entry could keep every
    /// machine name correct and still compare unequal, and then tapping the
    /// agent you are already on while viewing a resumed thread would pass that
    /// guard and wipe the thread for a fresh chat.
    func testAConversationMapsToItsOwnMachine() {
        let hermes = Conversation(
            id: "1", source: "hermes", node: "calypso",
            title: "t", updatedAt: 1, count: nil)
        XCTAssertEqual(AgentChoice.forConversation(hermes).machine, "Calypso")
        XCTAssertEqual(AgentChoice.forConversation(hermes), AgentChoice.all[2])

        let claude = Conversation(
            id: "2", source: "claude", node: "atlas",
            title: "t", updatedAt: 1, count: nil)
        XCTAssertEqual(AgentChoice.forConversation(claude).machine, "Atlas")
        XCTAssertEqual(AgentChoice.forConversation(claude), AgentChoice.all[0])
    }

    /// A fourth agent box would otherwise fall back to Atlas, and resuming a
    /// calypso-shaped thread against /api/claude is a silent 404 rather than a
    /// visible error.
    func testAnUnknownNodeBuildsItsOwnChoiceRatherThanFallingBackToAtlas() {
        let conv = Conversation(
            id: "3", source: "hermes", node: "newbox",
            title: "t", updatedAt: 1, count: nil)
        let choice = AgentChoice.forConversation(conv)
        XCTAssertEqual(choice.agent, .hermes(node: "newbox"))
        XCTAssertEqual(choice.machine, "Newbox")
        XCTAssertNotEqual(choice.agent, .claude)
    }

    /// `forConversation` matches on source AND node, and nothing above holds it
    /// to the SOURCE half: dropping that half of the predicate leaves every
    /// other test in this class green, because no row they build has a source
    /// that disagrees with its node. This is the row that does. A Claude thread
    /// reported on the `hermes` box must NOT be handed the Hermes row and
    /// resumed against /api/hermes - it gets a choice built for what it
    /// actually is.
    func testSourceIsPartOfTheMatchNotJustNode() {
        let conv = Conversation(
            id: "4", source: "claude", node: "hermes",
            title: "t", updatedAt: 1, count: nil)
        let choice = AgentChoice.forConversation(conv)
        XCTAssertEqual(choice.agent, .claude)
        XCTAssertNotEqual(choice.agent, .hermes(node: "hermes"))
        XCTAssertEqual(choice.machine, "Hermes")
    }
}

final class ChatTargetTests: XCTestCase {
    func testAFreshChatCarriesTheAgentAndNoResume() {
        let t = ChatTarget.fresh(AgentChoice.fallback)
        XCTAssertEqual(t.agent, .claude)
        XCTAssertEqual(t.title, "Atlas")
        XCTAssertNil(t.resume)
    }

    func testResumingCarriesTheThreadsTitleAndRef() {
        let conv = Conversation(
            id: "abc", source: "hermes", node: "calypso",
            title: "the billing thread", updatedAt: 1, count: 3)
        let t = ChatTarget.resuming(conv)
        XCTAssertEqual(t.agent, .hermes(node: "calypso"))
        XCTAssertEqual(t.title, "the billing thread")
        XCTAssertEqual(t.resume, ResumeRef(source: "hermes", node: "calypso", id: "abc"))
    }

    /// Switching agent must produce a DIFFERENT value, or `.id()` does not
    /// rebuild and the previous agent's thread stays on screen under the new
    /// agent's name.
    ///
    /// ASSERTED ON THE PARTS, NOT ON THE WHOLE VALUE, and that is the point of
    /// this test rather than a stylistic choice. `XCTAssertNotEqual(atlas,
    /// hermes)` is what this used to say, and it CANNOT FAIL: `generation`
    /// makes any two targets unequal, so a whole-value comparison passes even
    /// when `fresh` ignores its argument entirely and hands back `.fallback`
    /// every time - which is a chat that shows Atlas's thread no matter which
    /// agent you picked. `choice` and `agent` are the fields that carry the
    /// meaning, so they are what gets compared. Do not "simplify" this back to
    /// one line; the one line is the test being blind.
    ///
    /// THE TITLE IS CHECKED HERE TOO, because `fresh` has two independent ways
    /// to be wrong and routing is only one of them. Every other test asserts a
    /// title on the fallback path, whose `machine` is "Atlas" - so hardcoding
    /// `title: "Atlas"` and ignoring `choice.machine` entirely leaves the whole
    /// suite green. That mutant is a correctly-ROUTED chat wearing the wrong
    /// LABEL: you are talking to Hermes while the header and the composer's
    /// "Ask Atlas" both say Atlas. A non-fallback title is what catches it.
    func testSwitchingAgentChangesTheTarget() {
        let atlas = ChatTarget.fresh(AgentChoice.all[0])
        let hermes = ChatTarget.fresh(AgentChoice.all[1])
        XCTAssertNotEqual(atlas.choice, hermes.choice)
        XCTAssertNotEqual(atlas.agent, hermes.agent)
        XCTAssertEqual(atlas.agent, .claude)
        XCTAssertEqual(hermes.agent, .hermes(node: "hermes"))
        XCTAssertEqual(hermes.title, "Hermes")
    }

    /// THE BUG THIS GUARDS. Without a generation, two fresh Atlas chats are
    /// equal values - so tapping New Chat while already on Atlas is a no-op and
    /// the thread you wanted to leave is still there, mid-conversation.
    func testTwoFreshChatsWithTheSameAgentAreStillDifferentTargets() {
        XCTAssertNotEqual(
            ChatTarget.fresh(AgentChoice.fallback),
            ChatTarget.fresh(AgentChoice.fallback))
    }

    /// Same reason, for re-tapping a row: it must reload rather than sit there.
    func testResumingTheSameThreadTwiceGivesTwoDifferentTargets() {
        let conv = Conversation(
            id: "abc", source: "claude", node: "atlas",
            title: "t", updatedAt: 1, count: nil)
        XCTAssertNotEqual(ChatTarget.resuming(conv), ChatTarget.resuming(conv))
    }

    /// The `conversation` vs `sessionId` trap `Agent.attach` exists for. A
    /// Claude thread's SECOND turn must attach by `conversation`; writing
    /// `sessionId` there resumes a session the CLI no longer has.
    func testAttachAfterAConversationEventIsPerAgent() {
        let claude = ChatTarget.fresh(AgentChoice.all[0])
        if case .conversation(let id) = claude.agent.attach(afterConversationEvent: "x") {
            XCTAssertEqual(id, "x")
        } else {
            XCTFail("Claude must attach by conversation id after the first turn")
        }

        let hermes = ChatTarget.fresh(AgentChoice.all[1])
        if case .sessionId(let id) = hermes.agent.attach(afterConversationEvent: "y") {
            XCTAssertEqual(id, "y")
        } else {
            XCTFail("Hermes has no conversation concept - it attaches by session id")
        }
    }
}

final class VoiceTargetTests: XCTestCase {
    /// The shell renders `.id(target)`, so two voice targets must differ, just
    /// as two `fresh` ones do - otherwise a second voice question arriving
    /// while the first thread is on screen would not rebuild onto the new
    /// thread's model.
    func testVoiceTargetsAreAtlasAndEachIsNew() {
        let a = ChatTarget.voice()
        let b = ChatTarget.voice()
        XCTAssertTrue(a.isVoice)
        XCTAssertEqual(a.choice, .fallback)
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(ChatTarget.fresh(.fallback).isVoice)
    }
}
