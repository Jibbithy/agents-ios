import CryptoKit
import Foundation
import Observation
import os

/// The hub's approval routes. HubClient in the app, a fake in tests.
protocol MailHub: Sendable {
    func approvalsPending() async throws -> [Approval]
    func mailApprove(id: String, sig: String) async throws
    func mailCancel(id: String) async throws
}

extension HubClient: MailHub {}

/// Everything waiting on the user (emails, texts, calendar changes), and the
/// one place any of them is approved. Voice, the card and the notification
/// action all call `approve` here.
@Observable @MainActor
final class MailApprovals {
    static let shared = MailApprovals(hub: HubClient.shared, key: { ApprovalKey.load() })

    private(set) var pending: [Approval] = []
    @ObservationIgnored private let hub: MailHub
    @ObservationIgnored private let key: () -> SymmetricKey?
    /// Ids already read aloud, so each proposal is voiced once.
    @ObservationIgnored private var voiced = Set<String>()

    init(hub: MailHub, key: @escaping () -> SymmetricKey?) {
        self.hub = hub
        self.key = key
    }

    func refresh() async {
        do { pending = try await hub.approvalsPending() } catch {
            // KEPT, NOT CLEARED: a fetch that failed says nothing about what
            // is pending. And SAID: from the voice session a read-back that
            // never comes looks exactly like this.
            Logger.mail.error("Mail: the pending approvals could not be fetched: \(String(describing: error), privacy: .public)")
        }
    }

    /// For the voice session: the newest pending item not yet read aloud.
    func nextUnvoiced() async -> Approval? {
        await refresh()
        guard let p = pending.last(where: { !voiced.contains($0.id) }) else { return nil }
        voiced.insert(p.id)
        return p
    }

    /// Returns the sentence to say or show.
    func approve(_ p: Approval) async -> String {
        guard let key = key() else { return "No approval key on this phone. Add it in Settings." }
        guard p.isIntact else { return "This \(p.noun) changed on its way to the phone. Not doing it." }
        // Signs the hash of what is SHOWN, never the hub's copy of it.
        let sig = ApprovalKey.sign(key: key, id: p.id, hash: p.computedHash, expiresAt: p.expiresAt)
        do {
            try await hub.mailApprove(id: p.id, sig: sig)
            pending.removeAll { $0.id == p.id }
            return p.doneSentence
        } catch HubError.http(409, _) {
            // Expired, already used, or (calendar) the event changed since.
            pending.removeAll { $0.id == p.id }
            return "That one expired or changed. Ask again."
        } catch {
            return "Couldn't do it. It's still waiting."
        }
    }

    func cancel(_ p: Approval) async -> String {
        try? await hub.mailCancel(id: p.id)
        pending.removeAll { $0.id == p.id }
        return "Cancelled. Nothing done."
    }
}
