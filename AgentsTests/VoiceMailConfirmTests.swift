import XCTest

@testable import Agents

@MainActor final class FakeMailConfirmer: MailConfirming {
    var next: Approval?
    private(set) var approved: [String] = []
    private(set) var cancelled: [String] = []
    func nextUnvoiced() async -> Approval? {
        defer { next = nil }
        return next
    }
    func approve(_ p: Approval) async -> String {
        approved.append(p.id)
        return "Sent."
    }
    func cancel(_ p: Approval) async -> String {
        cancelled.append(p.id)
        return "Cancelled. Nothing sent."
    }
}

@MainActor
final class VoiceMailConfirmTests: XCTestCase {
    let item = Approval(
        mail: MailPending(
            id: "p_1", hash: String(repeating: "a", count: 64), expiresAt: 1,
            message: .init(to: ["user2@example.com"], cc: [], bcc: [], subject: "Friday", body: "Running late", in_reply_to: nil)))

    private func until(_ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting", file: file, line: line)
    }

    private func rig(confirm: String?) -> (Rig, FakeMailConfirmer) {
        let r = Rig(heard: "email alex", answer: .reply("Drafted it."))
        r.listener.queue = ["email alex", confirm]
        let mail = FakeMailConfirmer()
        mail.next = item
        r.session.mail = mail
        return (r, mail)
    }

    func testSendApprovesAfterTheAppsOwnReadBack() async {
        let (r, mail) = rig(confirm: "send it")
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.speaker.spoken, [item.readBack, "Sent."], "the read-back is the answer; Atlas's reply stays in the chat")
        XCTAssertEqual(mail.approved, ["p_1"])
        XCTAssertEqual(mail.cancelled, [])
        XCTAssertEqual(r.audio.ends, 1)
    }

    func testCancel() async {
        let (r, mail) = rig(confirm: "cancel")
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(mail.cancelled, ["p_1"])
        XCTAssertEqual(mail.approved, [])
        XCTAssertEqual(r.speaker.spoken.last, "Cancelled. Nothing sent.")
    }

    func testSilenceLeavesItOnScreen() async {
        let (r, mail) = rig(confirm: nil)
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(mail.approved, [])
        XCTAssertEqual(mail.cancelled, [])
        XCTAssertEqual(r.speaker.spoken, [item.readBack, "Left it on screen. Tap Send when you're ready."])
        XCTAssertEqual(r.asker.asked, ["email alex"])
    }

    func testAChangeCancelsTheProposalAndAsksAtlas() async {
        let (r, mail) = rig(confirm: "send it to Jordan instead")
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(mail.cancelled, ["p_1"], "the text the user turned away from cannot go out on a stray tap")
        XCTAssertEqual(mail.approved, [])
        XCTAssertEqual(r.asker.asked, ["email alex", "send it to Jordan instead"], "the change is the next question, asked without a fresh listen")
        XCTAssertEqual(r.listener.listens, 2)
        // Nothing new pending after the second turn: its reply is read as usual.
        XCTAssertEqual(r.speaker.spoken, [item.readBack, "Drafted it."])
    }

    func testDismissedAtTheReadBackCancelsAndEnds() async {
        let (r, mail) = rig(confirm: "Dismissed.")
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(mail.cancelled, ["p_1"])
        XCTAssertEqual(r.asker.asked, ["email alex"], "a goodbye is the app's, never sent to Atlas")
        XCTAssertEqual(r.speaker.spoken, [item.readBack])
    }

    func testNoPendingEmailBehavesAsBefore() async {
        let (r, mail) = rig(confirm: "send")
        mail.next = nil
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.speaker.spoken, ["Drafted it."])
        XCTAssertEqual(r.listener.listens, 1)
    }

    /// With echo cancellation on, a reply is read with a listen held over it.
    /// The read-back must not be: Atlas saying "Say send" could otherwise be
    /// heard as the user saying it. Held mid read-back, no listen may be open.
    func testTheReadBackIsNotListenedOver() async {
        let (r, mail) = rig(confirm: "send")
        r.audio.echoCancelled = true
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.speaker.speakingNow == [self.item.readBack])
        let listensAtReadBack = r.listener.listens
        let patientsAtReadBack = r.listener.patients
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(r.listener.listens, listensAtReadBack)
        XCTAssertEqual(r.listener.patients, patientsAtReadBack)
        r.speaker.release()
        await until(r.speaker.speakingNow == ["Sent."])
        r.speaker.release()
        await until(r.finished)
        XCTAssertEqual(mail.approved, ["p_1"])
        XCTAssertEqual(r.listener.listens, listensAtReadBack + 1)
    }
}
