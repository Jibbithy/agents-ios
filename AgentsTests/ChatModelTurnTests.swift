// AgentsTests/ChatModelTurnTests.swift
import XCTest

@testable import Agents

/// The two ways a voice ask is refused without a turn starting. Nothing here
/// reaches the hub: a turn that did start would need a live stream.
@MainActor
final class ChatModelTurnTests: XCTestCase {
    /// Blank words start nothing, so there is nothing to await - and a
    /// half-typed draft in the same chat is not the ask's to touch.
    func testAskingBlankTextStartsNoTurn() async {
        let model = ChatModel(agent: .claude, title: "Atlas")
        model.draft = "half typed"
        let started = await model.ask("  \n ")
        XCTAssertFalse(started)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.bubbles.isEmpty)
        XCTAssertEqual(model.draft, "half typed")
    }

    /// A second ask while a turn runs is refused BEFORE it touches `onTool`,
    /// or its cleanup would unhook the running ask's "Running Bash…" line.
    func testARefusedAskLeavesTheRunningAsksToolCallback() async {
        let model = ChatModel(agent: .claude, title: "Atlas")
        model.busy = true
        model.onTool = { _ in }
        let result = await ChatModelTurn(model).ask("is atlas up") { _ in }
        XCTAssertEqual(result, .failed("Still answering."))
        XCTAssertNotNil(model.onTool)
        XCTAssertTrue(model.bubbles.isEmpty)
    }
}
