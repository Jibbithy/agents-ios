import XCTest

@testable import Agents

final class ApprovalKeyTests: XCTestCase {
    /// The same vector as mailgate's test/approval.test.js.
    func testMatchesNodeVector() throws {
        let key = try XCTUnwrap(ApprovalKey.parse("BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc="))
        let sig = ApprovalKey.sign(key: key, id: "p_test", hash: String(repeating: "a", count: 64), expiresAt: 1_790_000_000_000)
        XCTAssertEqual(sig, "216a2c5f06ecaaf6f0b4fe774fb503f43903b5a4de566c1bdc6332425bd5fc3e")
    }

    func testParseRejectsWrongLengthAndGarbage() {
        XCTAssertNil(ApprovalKey.parse("abc"))
        XCTAssertNil(ApprovalKey.parse(Data(count: 16).base64EncodedString()))
        XCTAssertNotNil(ApprovalKey.parse("  " + Data(count: 32).base64EncodedString() + "\n"))
    }
}
