// AgentsTests/TokenMigrationTests.swift
import Security
import XCTest

@testable import Agents

/// What `TokenStore.migrateToSharedGroup` writes, at every launch and every
/// activation of both apps.
///
/// THE BUG THIS PINS: it used to delete the shared token and add it back on
/// every launch, ignoring the add's result - on a locked phone too, once the
/// token became readable after the first unlock. One failed add and neither
/// app had a token. Only the plan and the stop-at-first-failure loop are
/// tested; the Keychain calls under them cannot run on an unsigned simulator
/// (see HubTokenTests).
final class TokenMigrationTests: XCTestCase {
    private let shared = "TEAM.com.example.shared"
    private let bundle = "TEAM.com.example.rackcontrol"
    private let whenUnlocked = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

    /// Every launch but the first: nothing to do, so NOTHING is written.
    func testATokenAlreadyRightIsNotTouched() {
        let steps = TokenStore.plan([.init(group: shared, accessible: TokenStore.accessible)])
        XCTAssertEqual(steps, [])
    }

    /// The 2026-09-22 upgrade: in place, never a delete.
    func testAnOldClassIsUpgradedInPlace() {
        let steps = TokenStore.plan([.init(group: shared, accessible: whenUnlocked)])
        XCTAssertEqual(steps, [.upgrade(group: shared)])
    }

    /// A pre-sharing Rack Control token: the shared copy is added BEFORE the
    /// legacy one is deleted, so there is never a moment with no token.
    func testALegacyCopyIsCopiedBeforeItIsDropped() {
        let steps = TokenStore.plan([.init(group: bundle, accessible: whenUnlocked)])
        XCTAssertEqual(steps, [.copyToShared(from: bundle), .dropLegacy(group: bundle)])
    }

    /// Both copies: the shared one wins (every save lands there, so it is the
    /// newer) and is fixed before the legacy one goes.
    func testTheSharedCopyIsFixedBeforeALegacyOneIsDropped() {
        let steps = TokenStore.plan([
            .init(group: bundle, accessible: whenUnlocked),
            .init(group: shared, accessible: whenUnlocked),
        ])
        XCTAssertEqual(steps, [.upgrade(group: shared), .dropLegacy(group: bundle)])
    }

    func testNoTokenPlansNothing() {
        XCTAssertEqual(TokenStore.plan([]), [])
    }

    /// A failed copy - a locked phone, a full Keychain - must not go on to
    /// delete the only copy there is.
    func testAFailedStepStopsEverythingAfterIt() {
        var ran: [TokenStore.Step] = []
        TokenStore.run([.copyToShared(from: bundle), .dropLegacy(group: bundle)]) { step in
            ran.append(step)
            return false
        }
        XCTAssertEqual(ran, [.copyToShared(from: bundle)])
    }
}
