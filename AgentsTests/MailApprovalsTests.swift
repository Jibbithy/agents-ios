import CryptoKit
import XCTest

@testable import Agents

@MainActor
final class MailApprovalsTests: XCTestCase {
    final class FakeMailHub: MailHub, @unchecked Sendable {
        var pending: [Approval] = []
        var approved: [(String, String)] = []
        var cancelled: [String] = []
        var approveError: Error?
        func approvalsPending() async throws -> [Approval] { pending }
        func mailApprove(id: String, sig: String) async throws {
            if let e = approveError { throw e }
            approved.append((id, sig))
        }
        func mailCancel(id: String) async throws { cancelled.append(id) }
    }

    let key = ApprovalKey.parse("BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=")!
    let message = MailPending.Message(to: ["user@example.com"], cc: [], bcc: [], subject: "s", body: "b", in_reply_to: nil)
    /// An item whose hash matches its message, as mailgate would send it.
    func item(_ id: String) -> Approval {
        let draft = MailPending(id: id, hash: "", expiresAt: 1_790_000_000_000, message: message)
        return Approval(mail: MailPending(id: id, hash: draft.computedHash, expiresAt: 1_790_000_000_000, message: message))
    }

    func testApproveSignsWithTheKeyAndRemovesTheCard() async {
        let hub = FakeMailHub()
        hub.pending = [item("p_test")]
        let store = MailApprovals(hub: hub, key: { self.key })
        await store.refresh()
        XCTAssertEqual(store.pending.map(\.id), ["p_test"])
        let said = await store.approve(store.pending[0])
        let want = ApprovalKey.sign(key: key, id: "p_test", hash: item("p_test").computedHash, expiresAt: 1_790_000_000_000)
        XCTAssertEqual(hub.approved.first?.1, want)
        XCTAssertEqual(said, "Sent.")
        XCTAssertTrue(store.pending.isEmpty)
    }

    /// A hub that shows one message but relays another's hash gets nothing signed.
    func testAMessageThatDoesNotMatchItsHashIsNeverSigned() async {
        let hub = FakeMailHub()
        let good = item("p_1")
        let swapped = Approval(
            mail: MailPending(
                id: "p_1", hash: good.hash, expiresAt: good.expiresAt,
                message: .init(to: ["user@example.com"], cc: [], bcc: [], subject: "s", body: "harmless", in_reply_to: nil)))
        hub.pending = [swapped]
        let store = MailApprovals(hub: hub, key: { self.key })
        await store.refresh()
        let said = await store.approve(store.pending[0])
        XCTAssertTrue(hub.approved.isEmpty)
        XCTAssertEqual(said, "This email changed on its way to the phone. Not doing it.")
    }

    func testNoKeyMeansNoSend() async {
        let hub = FakeMailHub()
        hub.pending = [item("p_1")]
        let store = MailApprovals(hub: hub, key: { nil })
        await store.refresh()
        let said = await store.approve(store.pending[0])
        XCTAssertTrue(hub.approved.isEmpty)
        XCTAssertEqual(said, "No approval key on this phone. Add it in Settings.")
    }

    func testNextUnvoicedReturnsEachItemOnce() async {
        let hub = FakeMailHub()
        hub.pending = [item("p_1")]
        let store = MailApprovals(hub: hub, key: { self.key })
        let first = await store.nextUnvoiced()
        let second = await store.nextUnvoiced()
        XCTAssertEqual(first?.id, "p_1")
        XCTAssertNil(second)
    }

    func testExpiredApprovalSaysSo() async {
        let hub = FakeMailHub()
        hub.pending = [item("p_1")]
        hub.approveError = HubError.http(409, "")
        let store = MailApprovals(hub: hub, key: { self.key })
        await store.refresh()
        let said = await store.approve(store.pending[0])
        XCTAssertEqual(said, "That one expired or changed. Ask again.")
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testOtherFailureKeepsTheCard() async {
        let hub = FakeMailHub()
        hub.pending = [item("p_1")]
        hub.approveError = HubError.unreachable
        let store = MailApprovals(hub: hub, key: { self.key })
        await store.refresh()
        let said = await store.approve(store.pending[0])
        XCTAssertEqual(said, "Couldn't do it. It's still waiting.")
        XCTAssertEqual(store.pending.count, 1)
    }
}
