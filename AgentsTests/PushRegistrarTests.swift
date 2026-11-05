// AgentsTests/PushRegistrarTests.swift
import XCTest

@testable import Agents

/// The one pure piece of the push path. Everything else in `PushRegistrar` is
/// APNs, a permission sheet or an embedded provisioning profile, none of which
/// exist in a simulator - but this is exactly where the silent failure lives,
/// so it is the one worth pinning.
final class PushRegistrarTests: XCTestCase {

    /// `deviceToken.description` has printed "32 bytes" since iOS 13, and an
    /// app that registered THAT string would look perfectly healthy right up
    /// until Apple rejected every push forever. Lowercase hex, no separators,
    /// no wrapper - the hub's TOKEN_RE is /^[0-9a-f]{64,200}$/i.
    func testTokenIsLowercaseHexWithNoPunctuation() {
        XCTAssertEqual(PushRegistrar.hex(Data([0x00, 0x0f, 0xa1, 0xff])), "000fa1ff")
        // 32 bytes in, 64 characters out - the length APNs actually issues.
        XCTAssertEqual(PushRegistrar.hex(Data(repeating: 0xab, count: 32)).count, 64)
        XCTAssertEqual(PushRegistrar.hex(Data()), "")
    }
}
