// AgentsTests/ChatHandleTests.swift
import XCTest

@testable import Agents

/// Which voice session the pencil may cancel: only one putting its question
/// to the chat the pencil is leaving.
@MainActor
final class ChatHandleTests: XCTestCase {
    /// The composer mic asks the chat on screen, through a `ChatModelTurn`.
    func testTheComposerMicsQuestionIsIntoTheChatOnScreen() {
        let handle = ChatHandle()
        let model = ChatModel(agent: .claude, title: "Atlas")
        handle.register(model)
        XCTAssertTrue(handle.isAsked(by: ChatModelTurn(model)))
    }

    /// A question into a chat left behind - its turn runs on - or into the
    /// voice chat off screen is not the pencil's, and nor is no session.
    func testAnyOtherQuestionIsNot() {
        let handle = ChatHandle()
        handle.register(ChatModel(agent: .claude, title: "Atlas"))
        XCTAssertFalse(handle.isAsked(by: ChatModelTurn(ChatModel(agent: .claude, title: "Atlas"))))
        XCTAssertFalse(handle.isAsked(by: FakeAsker(answer: .stopped)))
        XCTAssertFalse(handle.isAsked(by: nil))
    }
}
