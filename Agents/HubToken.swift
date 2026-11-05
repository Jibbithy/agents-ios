import Foundation
import Observation

/// The hub token the running app is using, and the ONE place that decides it
/// has gone bad.
///
/// WHY THIS EXISTS. The token was rotated on atlas, the phone still held the
/// old one, every call answered 401 - and the app said "That token was
/// rejected." on a screen with no field to paste a new one. RootView picked
/// between TokenEntryView and the app once, from a `@State` seeded at launch,
/// and nothing a 401 did could ever reach it. Now every 401 from the hub lands
/// in `rejected(_:)`, which forgets the stored token and sets `value` to nil,
/// and RootView observes `needsToken` and puts the token screen back.
///
/// A LOCKED KEYCHAIN IS NEVER A VERDICT. Agents' voice intent runs on a locked
/// phone, and a read there can answer "locked" (see TokenStore.Read). That says
/// nothing about whether the token is good, so it neither clears the item nor
/// takes `value` away - otherwise a question asked from the lock screen would
/// greet the user with the token screen over an intact token.
///
/// SAME FILE IN BOTH APPS, like TokenStore. Clearing here clears the shared
/// Keychain item, so the other app finds no token on its next call, routes
/// that into `rejected(nil)` itself, and lands on its own token screen - which
/// is right, because it was holding the same dead token.
@MainActor
@Observable
final class HubToken {
    static let shared = HubToken()

    /// The token, nil when the Keychain has none. Only ever set from what the
    /// Keychain holds (or was just told to hold), never from a guess - so a
    /// locked read leaves it as it was.
    private(set) var value: String? = nil

    /// The last read here found the Keychain locked, so a nil `value` is
    /// unknown rather than absent. Only this type's own reads clear it - the
    /// next `refresh()` (the app calls it whenever the scene becomes active)
    /// or `rejected` that gets an answer - or `saved`.
    private(set) var keychainLocked = false

    /// What RootView switches on: true shows TokenEntryView. Never true on a
    /// locked read alone - only when the Keychain has said it holds nothing.
    var needsToken: Bool { value == nil && !keychainLocked }

    @ObservationIgnored private let read: () -> TokenStore.Read
    @ObservationIgnored private let save: (String) -> Void
    @ObservationIgnored private let clear: () -> Void

    /// The closures are the seam for tests, which must not touch the real
    /// Keychain: an unsigned simulator build has no keychain entitlement at
    /// all, so every read there is `.missing`.
    init(
        read: @escaping () -> TokenStore.Read = { TokenStore.read() },
        save: @escaping (String) -> Void = { TokenStore.save($0) },
        clear: @escaping () -> Void = { TokenStore.clear() }
    ) {
        self.read = read
        self.save = save
        self.clear = clear
        take(read())
    }

    /// Re-reads the Keychain. A launch that found it locked - the voice intent
    /// on a phone not unlocked since it restarted - otherwise keeps not knowing
    /// until something is rejected, however long the app then stays resident.
    func refresh() { take(read()) }

    /// A token TokenEntryView has already proved against the hub.
    func saved(_ token: String) {
        save(token)
        value = token
        keychainLocked = false
    }

    /// The hub answered 401 to a request that carried `sent` - or nil, when
    /// there was no stored token to send at all.
    ///
    /// COMPARE-AND-CLEAR, and against the Keychain rather than `value`. A
    /// request that left with the OLD token can come back 401 after the new
    /// one has been pasted in; clearing unconditionally would throw the good
    /// token away and bounce straight back to the token screen. Re-reading
    /// afterwards also picks up a token the other app stored in the meantime.
    ///
    /// A locked read matches no `sent`, so it clears nothing, and `take`
    /// leaves `value` alone - see the type's doc.
    func rejected(_ sent: String?) {
        if let sent, read() == .token(sent) { clear() }
        take(read())
    }

    /// Adopts one Keychain answer.
    private func take(_ r: TokenStore.Read) {
        switch r {
        case .token(let t):
            value = t
            keychainLocked = false
        case .missing:
            value = nil
            keychainLocked = false
        case .locked: keychainLocked = true
        }
    }
}
