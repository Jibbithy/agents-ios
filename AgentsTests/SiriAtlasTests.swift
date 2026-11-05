// AgentsTests/SiriAtlasTests.swift
import AppIntents
import XCTest

@testable import Agents

/// "Hey Siri, Atlas" rests on two things a build can silently lose.
@MainActor
final class SiriAtlasTests: XCTestCase {

    /// THE SYNONYM IS WHAT MAKES "ATLAS" SAY ANYTHING TO SIRI: the app is
    /// called Agents, and every App Shortcut phrase is built on
    /// `.applicationName`. It lives in the hand-written Agents/Info.plist
    /// (the INFOPLIST_KEY_ generator cannot express an array of dictionaries);
    /// this reads the plist the built app actually carries.
    func testAtlasIsAnAlternativeAppName() throws {
        let names = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "INAlternativeAppNames") as? [[String: String]])
        XCTAssertTrue(names.contains { $0["INAlternativeAppName"] == "Atlas" }, "\(names)")
    }

    /// Opens the app when it can - the conversation on screen - and runs in
    /// the background when it cannot (a locked phone), rather than stopping
    /// at a Face ID prompt.
    func testSiriIntentPrefersForegroundButMayRunInBackground() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("supportedModes is iOS 26+") }
        let modes = TalkToAtlasIntent.supportedModes
        XCTAssertTrue(modes.contains(.background))
        XCTAssertTrue(modes.contains(.foreground(.immediate)))
    }

    /// Same no-Face-ID decision as `ListenIntent`: a locked phone must work.
    func testSiriIntentRunsOnALockedPhone() {
        XCTAssertEqual(TalkToAtlasIntent.authenticationPolicy, .alwaysAllowed)
        XCTAssertEqual(ListenIntent.authenticationPolicy, .alwaysAllowed)
    }
}
