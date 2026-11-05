// AgentsTests/HubTokenTests.swift
import XCTest

@testable import Agents

/// A rotated hub token must put the app back on the token screen.
///
/// THE BUG THIS PINS: the token was rotated on atlas, the phone kept the old
/// one, the hub answered 401, and the app said "That token was rejected." with
/// no field anywhere to paste the new one. None of this touches the real
/// Keychain - an unsigned simulator build has no keychain entitlement, so
/// every load there is nil and a Keychain-backed test would pass for the
/// wrong reason.
@MainActor
final class HubTokenTests: XCTestCase {

    /// Stands in for the Keychain item. `locked` is the phone refusing to
    /// decrypt it (errSecInteractionNotAllowed): the item is still there.
    final class FakeStore {
        var token: String?
        var locked = false
        init(_ token: String?) { self.token = token }
        var read: TokenStore.Read {
            if locked { return .locked }
            return token.map(TokenStore.Read.token) ?? .missing
        }
    }

    private func hubToken(_ store: FakeStore) -> HubToken {
        HubToken(
            read: { store.read },
            save: { store.token = $0 },
            clear: { store.token = nil })
    }

    private func client(status: Int, reading read: TokenStore.Read, to tokens: HubToken) -> HubClient {
        StubHub.status = status
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubHub.self]
        return HubClient(
            session: URLSession(configuration: c),
            token: { read },
            onRejected: { await tokens.rejected($0) })
    }

    // MARK: - end to end through HubClient

    /// THE ONE THAT MATTERS: a 401 from the hub forgets the stored token and
    /// takes `value` to nil, which is what RootView swaps to TokenEntryView on.
    func testA401ClearsTheTokenAndReturnsToTokenEntry() async {
        let store = FakeStore("old")
        let tokens = hubToken(store)
        XCTAssertEqual(tokens.value, "old")

        let hub = client(status: 401, reading: .token("old"), to: tokens)
        do {
            _ = try await hub.conversations()
            XCTFail("a 401 must throw")
        } catch HubError.unauthorized {
        } catch {
            XCTFail("expected .unauthorized, got \(error)")
        }

        XCTAssertNil(store.token, "the rejected token is still in the store")
        XCTAssertNil(tokens.value, "RootView would still be showing the app")
        XCTAssertTrue(tokens.needsToken)
    }

    /// Anything that is not a 401 says nothing about the token. Dropping it on
    /// a 502 from a sleeping node would make every hiccup a re-paste.
    func testOtherFailuresLeaveTheTokenAlone() async {
        let store = FakeStore("good")
        let tokens = hubToken(store)

        let hub = client(status: 502, reading: .token("good"), to: tokens)
        _ = try? await hub.conversations()

        XCTAssertEqual(store.token, "good")
        XCTAssertEqual(tokens.value, "good")
    }

    /// No stored token at all - the other app already cleared the shared item.
    /// That must reach the token screen too, without a network call.
    func testNoStoredTokenReturnsToTokenEntry() async {
        let store = FakeStore("stale")
        let tokens = hubToken(store)
        store.token = nil  // cleared under us, by the other app

        let hub = client(status: 200, reading: .missing, to: tokens)
        do {
            _ = try await hub.conversations()
            XCTFail("no token must throw")
        } catch HubError.unauthorized {
        } catch {
            XCTFail("expected .unauthorized, got \(error)")
        }
        XCTAssertNil(tokens.value)
        XCTAssertTrue(tokens.needsToken)
    }

    // MARK: - a locked phone

    /// THE LOCK-SCREEN VOICE BUG: the phone refused to decrypt the token, the
    /// request read that as "no token", and `rejected(nil)` put an intact
    /// token behind the token screen. A locked read must fail the request as
    /// .locked and leave the store, `value` and RootView exactly as they were.
    func testALockedKeychainFailsTheRequestAndKeepsTheToken() async {
        let store = FakeStore("good")
        let tokens = hubToken(store)
        store.locked = true

        let hub = client(status: 200, reading: .locked, to: tokens)
        do {
            _ = try await hub.conversations()
            XCTFail("a locked Keychain must throw")
        } catch HubError.locked {
        } catch {
            XCTFail("expected .locked, got \(error)")
        }

        XCTAssertEqual(store.token, "good", "a locked read cleared the token")
        XCTAssertEqual(tokens.value, "good")
        XCTAssertFalse(tokens.needsToken, "RootView would show the token screen")
    }

    /// Belt and braces for `rejected` itself: a 401 whose re-read finds the
    /// phone locked cannot compare the tokens, so it must clear nothing.
    func testRejectedWhileLockedChangesNothing() {
        let store = FakeStore("good")
        let tokens = hubToken(store)
        store.locked = true

        tokens.rejected("good")
        tokens.rejected(nil)

        XCTAssertEqual(store.token, "good")
        XCTAssertEqual(tokens.value, "good")
        XCTAssertFalse(tokens.needsToken)
    }

    /// Launched by the voice intent before the phone has been unlocked since
    /// it restarted: nothing is readable, and that is not "no token". Once a
    /// read gets an answer, the answer counts.
    func testLockedAtLaunchIsNotTheTokenScreen() {
        let store = FakeStore("good")
        store.locked = true
        let tokens = hubToken(store)

        XCTAssertNil(tokens.value)
        XCTAssertFalse(tokens.needsToken)

        store.locked = false
        store.token = nil  // cleared by the other app meanwhile
        tokens.rejected(nil)
        XCTAssertTrue(tokens.needsToken, "a real missing read must still reach the token screen")
    }

    /// The same locked launch, then the phone is unlocked and the app comes to
    /// the front: `refresh` (on scene active) learns the token, and the flag
    /// is gone, so a later missing read is believed again.
    func testRefreshAfterALockedLaunchLearnsTheToken() {
        let store = FakeStore("good")
        store.locked = true
        let tokens = hubToken(store)
        XCTAssertTrue(tokens.keychainLocked)

        store.locked = false
        tokens.refresh()

        XCTAssertEqual(tokens.value, "good")
        XCTAssertFalse(tokens.keychainLocked)
        XCTAssertFalse(tokens.needsToken)
    }

    // MARK: - HubToken on its own

    /// A request that left with the OLD token can 401 after the new one was
    /// saved. It must not throw the new one away.
    func testALate401ForAnOldTokenKeepsTheNewOne() {
        let store = FakeStore("old")
        let tokens = hubToken(store)
        tokens.saved("new")

        tokens.rejected("old")

        XCTAssertEqual(store.token, "new")
        XCTAssertEqual(tokens.value, "new")
    }

    func testSavingANewTokenLeavesTheTokenScreen() {
        let store = FakeStore(nil)
        let tokens = hubToken(store)
        XCTAssertNil(tokens.value)

        tokens.saved("fresh")

        XCTAssertEqual(store.token, "fresh")
        XCTAssertEqual(tokens.value, "fresh")
    }
}

/// Answers every request with `status`, without the network.
final class StubHub: URLProtocol {
    nonisolated(unsafe) static var status = 401

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let resp = HTTPURLResponse(
            url: request.url!, statusCode: Self.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"stub"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
