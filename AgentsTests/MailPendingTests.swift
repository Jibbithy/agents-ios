import XCTest

@testable import Agents

final class MailPendingTests: XCTestCase {
    let json = """
        {"pending":[{"id":"p_1","hash":"\(String(repeating: "a", count: 64))","expiresAt":1790000000000,
          "message":{"to":["user2@example.com"],"cc":[],"bcc":[],"subject":"Friday","body":"Running late.","in_reply_to":null}}]}
        """.data(using: .utf8)!

    func testDecodes() throws {
        let page = try JSONDecoder().decode(MailPendingPage.self, from: json)
        XCTAssertEqual(page.pending.first?.id, "p_1")
        XCTAssertEqual(page.pending.first?.expiresAt, 1_790_000_000_000)
        XCTAssertEqual(page.pending.first?.message.to, ["user2@example.com"])
    }

    func testReadBackIsTheAppsOwnWordsFromTheHashedFields() throws {
        let p = try JSONDecoder().decode(MailPendingPage.self, from: json).pending[0]
        XCTAssertEqual(
            p.readBack,
            "Email to user2@example.com. Subject: Friday. It says: Running late. Say send, or cancel.")
    }

    /// A vector computed with mailgate's canonical hash over this fixture.
    func testComputedHashMatchesMailgate() {
        let p = MailPending(
            id: "p", hash: "555d176ba540ddfb25d3313264352230804b672124303935b2a05c54d7fd155c", expiresAt: 1,
            message: .init(to: ["user2@example.com"], cc: [], bcc: [], subject: "Friday", body: "Running late \u{2014} \u{e9}", in_reply_to: nil))
        XCTAssertEqual(p.computedHash, p.hash)
        XCTAssertTrue(p.isIntact)
    }

    func testReplyIsSaidAloud() {
        let p = MailPending(
            id: "p", hash: "h", expiresAt: 1,
            message: .init(to: ["user@example.com"], cc: [], bcc: [], subject: "Re: x", body: "Yes", in_reply_to: "<m@x>"))
        XCTAssertTrue(p.readBack.contains("It's a reply in an existing thread."))
    }

    func testReadBackMentionsCcAndMissingSubject() {
        let p = MailPending(
            id: "p", hash: "h", expiresAt: 1,
            message: .init(to: ["user@example.com"], cc: ["user3@example.com"], bcc: [], subject: "", body: "Hi", in_reply_to: nil))
        XCTAssertEqual(p.readBack, "Email to user@example.com, copying user3@example.com. No subject. It says: Hi. Say send, or cancel.")
    }
}
