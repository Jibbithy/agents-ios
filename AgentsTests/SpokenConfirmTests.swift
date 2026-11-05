import XCTest

@testable import Agents

final class SpokenConfirmTests: XCTestCase {
    func testSend() {
        for s in ["send", "Send.", "send it", "Yes, send it.", "send it now", "okay send", "go ahead and send"] {
            XCTAssertEqual(SpokenConfirm.parse(s), .send, s)
        }
    }
    func testCancelWinsOverSend() {
        for s in [
            "cancel", "don't send", "Don\u{2019}t send", "no", "do not send it", "stop", "send... no wait cancel",
            "decline", "Never mind.", "nevermind", "forget it", "discard it",
        ] {
            XCTAssertEqual(SpokenConfirm.parse(s), .cancel, s)
        }
    }
    func testAnythingElseIsNeither() {
        for s in ["", "change the subject", "send it to Jordan instead", "what did it say", "resend"] {
            XCTAssertNil(SpokenConfirm.parse(s), s)
        }
        XCTAssertNil(SpokenConfirm.parse(nil))
    }
}
