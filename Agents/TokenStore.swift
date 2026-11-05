import Foundation
import Security

/// The hub credential, in the Keychain.
///
/// This is `x-rack-token`, the hub's shared secret - the same one ops/rackctl
/// uses - and it authorises Docker writes as well as reads. It is not a
/// preference, and losing the phone means rotating it on atlas.
///
/// SHARED BETWEEN RACK CONTROL AND AGENTS, and this file is identical in both
/// repos apart from Rack Control's DemoMode block in `read()`. Both declare
/// `$(AppIdentifierPrefix)com.example.shared` as the FIRST (and only) entry
/// in keychain-access-groups, which has two consequences this code depends on
/// and neither of which is obvious:
///
///   1. SecItemAdd with no kSecAttrAccessGroup lands in that first group. So
///      `save` needs no team prefix and no group of its own.
///   2. SecItemCopyMatching with no kSecAttrAccessGroup searches EVERY group
///      the app is entitled to, including its own implicit bundle group. So
///      `load` finds a token written by the old, un-shared build without
///      knowing anything about where it was written.
///
/// Together those mean nothing here has to discover the team prefix at
/// runtime: `migrateToSharedGroup` reads each copy's group off the copy itself.
///
/// `kSecAttrService` stays the literal string "com.example.rackcontrol" in
/// both apps. It names the CREDENTIAL, not the app holding it; renaming it
/// would orphan the existing item for no gain.
enum TokenStore {
    private static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.example.rackcontrol",
            kSecAttrAccount as String: "rack-hub-token",
        ]
    }

    /// ThisDeviceOnly so the token never rides an iCloud backup onto a second
    /// device. AFTER FIRST UNLOCK, NOT WHEN UNLOCKED: Agents' voice ListenIntent
    /// asks Atlas from a LOCKED phone (the Action Button, a lock-screen
    /// control) and has to send this token to do it. So the token is readable
    /// while the phone is locked, from the first unlock after a restart until
    /// the next restart - a deliberate trade-off, not an oversight.
    ///
    /// EVERY APP IN THE SHARED GROUP MUST AGREE. `migrateToSharedGroup` moves
    /// the item onto this class at every launch and activation, so two apps
    /// that disagreed would keep setting it back and forth.
    static var accessible: String { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String }

    /// What one Keychain read found.
    ///
    /// LOCKED IS NOT MISSING. errSecInteractionNotAllowed means the item is
    /// there and the phone will not decrypt it yet - before the first unlock
    /// since a restart, or a token an older build saved `WhenUnlocked` that
    /// has not been upgraded since (see `migrateToSharedGroup`). Read as
    /// "no token", that sent a lock-screen voice question to HubToken.rejected,
    /// which put a phone with a perfectly good token on the token screen.
    enum Read: Equatable, Sendable {
        case token(String)
        case missing
        case locked
    }

    static func read() -> Read {
        fetch()
    }

    /// One copy's data - any group's when `group` is nil, see (2) above.
    private static func fetch(group: String? = nil) -> Read {
        var q = base
        if let group { q[kSecAttrAccessGroup as String] = group }
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecInteractionNotAllowed { return .locked }
        // Every other failure - not found, and the missing entitlement of an
        // unsigned simulator build - is "no token", as it always was.
        guard status == errSecSuccess,
            let data = out as? Data,
            let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return .missing }
        return .token(s)
    }

    /// The token, or nil for missing AND locked alike. For callers with
    /// nothing to do differently when the phone is locked; anything that
    /// would send a missing token to HubToken.rejected must use `read()`.
    static func load() -> String? {
        if case .token(let t) = read() { return t }
        return nil
    }

    static func save(_ token: String) {
        // Deletes across every entitled group, then adds to the default one -
        // which is the shared group - so no legacy bundle-group copy survives
        // a new token.
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = accessible
        SecItemAdd(q as CFDictionary, nil)
    }

    static func clear() { SecItemDelete(base as CFDictionary) }

    // MARK: - Migration

    /// One stored copy of the token, as the Keychain describes it.
    struct Copy: Equatable {
        let group: String
        let accessible: String
        /// `<team>.com.example.shared`. Matched on the suffix so the team
        /// prefix never has to be known here.
        var isShared: Bool { group.hasSuffix(".com.example.shared") }
    }

    /// One write `migrateToSharedGroup` may make.
    enum Step: Equatable {
        /// Change the shared copy's accessibility in place.
        case upgrade(group: String)
        /// No shared copy yet: add one holding the token read from `from`.
        case copyToShared(from: String)
        /// Delete a copy outside the shared group.
        case dropLegacy(group: String)
    }

    /// Moves the token into the shared group, on the `accessible` class.
    ///
    /// Rack Control's first token was saved with no access group at all, so
    /// it lived in that app's implicit bundle-scoped group, where Agents cannot
    /// see it. Without this, installing Agents would ask for a token the user
    /// had already given - which reads as data loss even though nothing was
    /// lost. And an item keeps the accessibility it was ADDED with, so this is
    /// also the only thing that moves a token an older build saved
    /// `WhenUnlocked` onto `accessible`: the 2026-09-22 upgrade depends on it.
    ///
    /// RUNS AT EVERY LAUNCH AND EVERY ACTIVATION, INCLUDING ON A LOCKED PHONE
    /// (the voice intent's cold launch). It used to be a blind delete-then-add
    /// with the add's result ignored: one failed add there and BOTH apps had
    /// lost the token, and even a good one left a window in which the other
    /// app read "missing" and went to its token screen. So now:
    ///   - it reads each copy's group and class first, and when the token is
    ///     already where and how it should be - every launch but the first -
    ///     it writes nothing at all;
    ///   - a shared copy on the wrong class is changed IN PLACE with
    ///     SecItemUpdate, so there is never a moment with no token. On a
    ///     locked phone that update fails (the old class cannot be decrypted
    ///     yet), nothing is lost, and the next activation tries again;
    ///   - a legacy copy is deleted only AFTER the shared one is right, and
    ///     `run` stops at the first write that fails.
    /// A device with no token plans nothing.
    static func migrateToSharedGroup() {
        run(plan(copies())) { perform($0) }
    }

    /// The writes that take `copies` to exactly one shared copy on
    /// `accessible` - fixing the shared copy FIRST, so a legacy copy is never
    /// the last one standing when it is deleted.
    static func plan(_ copies: [Copy]) -> [Step] {
        let legacy = copies.filter { !$0.isShared }
        var steps: [Step]
        if let shared = copies.first(where: \.isShared) {
            steps = shared.accessible == accessible ? [] : [.upgrade(group: shared.group)]
        } else if let from = legacy.first {
            steps = [.copyToShared(from: from.group)]
        } else {
            return []
        }
        return steps + legacy.map { .dropLegacy(group: $0.group) }
    }

    /// Performs `steps` in order and STOPS AT THE FIRST FAILURE, so a legacy
    /// copy is only ever deleted once the shared one is in place.
    static func run(_ steps: [Step], _ perform: (Step) -> Bool) {
        for step in steps {
            guard perform(step) else { return }
        }
    }

    /// Every stored copy, by group and class. Attributes only: this must be
    /// able to answer on a locked phone without decrypting anything, because
    /// the "already right" case has to be free.
    private static func copies() -> [Copy] {
        var q = base
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
            let rows = out as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let group = row[kSecAttrAccessGroup as String] as? String,
                let cls = row[kSecAttrAccessible as String] as? String
            else { return nil }
            return Copy(group: group, accessible: cls)
        }
    }

    private static func perform(_ step: Step) -> Bool {
        switch step {
        case .upgrade(let group):
            var q = base
            q[kSecAttrAccessGroup as String] = group
            let change = [kSecAttrAccessible as String: accessible]
            return SecItemUpdate(q as CFDictionary, change as CFDictionary) == errSecSuccess
        case .copyToShared(let from):
            guard case .token(let t) = fetch(group: from) else { return false }
            var q = base
            q[kSecValueData as String] = Data(t.utf8)
            q[kSecAttrAccessible as String] = accessible
            return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        case .dropLegacy(let group):
            var q = base
            q[kSecAttrAccessGroup as String] = group
            return SecItemDelete(q as CFDictionary) == errSecSuccess
        }
    }
}
