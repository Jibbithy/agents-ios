import CryptoKit
import Foundation
import Security

/// The key that proves a human said "send". mailgate holds the other copy in
/// /etc/mailgate, unreadable by the atlas user, so neither Claude nor the hub
/// can make a signature. Pasted once from mailgate's install.sh output.
///
/// Stored like the hub token (see TokenStore): no kSecAttrAccessGroup, so it
/// lands in the app's first keychain group, with the same accessibility class.
enum ApprovalKey {
    private static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.example.agents.mail-approval",
            kSecAttrAccount as String: "mailgate-approval-key",
        ]
    }

    static func parse(_ text: String) -> SymmetricKey? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// Hex HMAC-SHA256 of "<id>.<hash>.<expiresAt>", the same bytes mailgate's
    /// src/approval.js signs.
    static func sign(key: SymmetricKey, id: String, hash: String, expiresAt: Int64) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(id).\(hash).\(expiresAt)".utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    static func load() -> SymmetricKey? {
        var q = base
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
            let data = out as? Data, data.count == 32
        else { return nil }
        return SymmetricKey(data: data)
    }

    @discardableResult
    static func save(_ text: String) -> Bool {
        guard let key = parse(text) else { return false }
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        q[kSecAttrAccessible as String] = TokenStore.accessible
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static var isSet: Bool { load() != nil }
}
