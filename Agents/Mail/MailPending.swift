import CryptoKit
import Foundation

/// A send Claude proposed and mailgate is holding.
///
/// THE PHONE DOES NOT TRUST THE HUB'S HASH. The hub runs as atlas, and so does
/// Claude: a patched hub could show one message and hand over another's hash.
/// So the phone recomputes the hash from the exact fields it shows and reads
/// aloud (`computedHash`), signs THAT, and refuses when it differs from what
/// mailgate reported (`isIntact`). mailgate then only sends if the signed hash
/// matches the message it stored.
struct MailPending: Codable, Equatable, Identifiable, Sendable {
    struct Message: Codable, Equatable, Sendable {
        let to: [String]
        let cc: [String]
        let bcc: [String]
        let subject: String
        let body: String
        let in_reply_to: String?
    }
    let id: String
    let hash: String
    let expiresAt: Int64
    let message: Message

    /// Read aloud before listening for "send". Built HERE from the fields
    /// mailgate hashed, never from Claude's reply, so what is heard is what
    /// is signed.
    var readBack: String {
        var s = "Email to \(message.to.joined(separator: ", "))"
        if !message.cc.isEmpty { s += ", copying \(message.cc.joined(separator: ", "))" }
        if !message.bcc.isEmpty { s += ", blind copying \(message.bcc.joined(separator: ", "))" }
        s += ". "
        s += message.subject.isEmpty ? "No subject. " : "Subject: \(message.subject). "
        var body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = body.last, !".!?".contains(last) { body += "." }
        if message.in_reply_to != nil { s += "It's a reply in an existing thread. " }
        return s + "It says: \(body) Say send, or cancel."
    }

    /// mailgate's src/canonical.js hashMessage, byte for byte: SHA-256 of
    /// "<utf8 length>:<field>" for to, cc, bcc (joined by ","), subject, body,
    /// in_reply_to ("" when none).
    var hashFields: [String] {
        [
            message.to.joined(separator: ","), message.cc.joined(separator: ","),
            message.bcc.joined(separator: ","), message.subject, message.body,
            message.in_reply_to ?? "",
        ]
    }

    var computedHash: String {
        let input = hashFields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What is shown is what mailgate holds. False means something between
    /// mailgate and this phone changed the message: never approve it.
    var isIntact: Bool { computedHash == hash }
}

struct MailPendingPage: Codable, Sendable { let pending: [MailPending] }
