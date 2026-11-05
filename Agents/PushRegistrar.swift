import UIKit
import UserNotifications

/// Remote notifications: asking for them, telling the hub where to send them,
/// deciding what a banner does while the app is already open, and what a tap
/// on one is able to do.
///
/// WHY THIS APP NEEDS ANY OF THIS. A turn here can legitimately think for
/// minutes - `SSEStream`'s session carries a ten-minute resource timeout for
/// exactly that reason - and iOS suspends the process within seconds of the
/// screen locking. `hub/turns.js` exists so that does not cost the answer: the
/// turn and the socket are separate objects, the run continues into a buffer,
/// and the thread is waiting in the drawer afterwards. What has been missing is
/// any way for the phone to LEARN that it landed. Without a push the only
/// discovery mechanism is remembering to open the app, which for a nine-minute
/// turn means finding out tomorrow. A push is the one channel that reaches a
/// suspended app, so this file is what makes the detachable turn worth having.
///
/// THE HUB ONLY SENDS WHEN NOBODY WAS WATCHING. `notifyTurnFinished` in
/// hub/server.js returns early while the turn still has a subscriber, so a
/// banner never arrives for the answer already streaming on screen.
@MainActor
final class PushRegistrar: NSObject {
    static let shared = PushRegistrar()

    /// Set once the hub has accepted a token, so a re-launch does not re-POST
    /// the same registration on every cold start of the same session.
    private var registered = false

    /// In flight right now. NOT the same question as `registered`, and it is
    /// the one that matters for correctness: `enable()` is driven by a SwiftUI
    /// `.task`, which re-runs whenever its branch reappears, so two calls can
    /// overlap across the `await` on requestAuthorization and each start its
    /// own registration POST for the same token. iOS coalesces the permission
    /// sheet itself - it asks exactly once per install, ever - so the visible
    /// symptom of leaving this out is not a double prompt but a doubled
    /// round trip, which is the kind of thing nothing ever notices.
    private var enabling = false

    /// Ask, then register. Safe to call repeatedly.
    ///
    /// CALLED FROM THE `ChatShell()` BRANCH, not at launch. That branch is
    /// reached only once a hub token exists, so the permission sheet lands on
    /// someone who has seen what the app is and has a hub to be notified BY.
    /// At launch it would be the first thing a new install ever showed, before
    /// the token screen, and a "no" there is close to permanent - iOS only
    /// asks once; after that it is a trip to Settings.
    ///
    /// DELIBERATELY NOT SHORT-CIRCUITED ON `registered`. Repeating the whole
    /// dance on a later appearance IS the token-refresh path: a device token
    /// is not stable across a restore, a reinstall or an OS update, and asking
    /// APNs every time is the only way to learn the new one. The hub upserts,
    /// so a repeat costs one request - see registerDevice in hub/push.js.
    func enable() async {
        if enabling { return }
        enabling = true
        defer { enabling = false }

        let center = UNUserNotificationCenter.current()
        // An assignment, not an append: setting the same delegate twice is a
        // no-op, which is what makes the re-run above harmless.
        center.delegate = self
        // CANCEL ONLY on a pending-email banner. There is deliberately no Send:
        // the banner's text is written by the hub and the body isn't shown,
        // so a lock-screen Send would approve a message nobody saw. Tapping
        // the banner opens the app, where the card shows it all.
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "MAIL_PENDING",
                actions: [
                    UNNotificationAction(identifier: "MAIL_CANCEL", title: "Cancel", options: [.destructive])
                ], intentIdentifiers: [])
        ])

        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // A throw here is the system declining to ask at all - a screen-time
            // restriction, or a profile. Not an error worth surfacing: the app
            // works exactly as it did before push existed.
            return
        }
        guard granted else { return }

        // MUST BE THE MAIN THREAD. registerForRemoteNotifications() off the
        // main actor is a runtime complaint at best and a silent no-op at
        // worst - the callback simply never fires and the phone looks like it
        // registered. The @MainActor on this type is what guarantees it.
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// APNs handed us a token. Hex-encode it and tell the hub.
    func received(deviceToken: Data) {
        let hex = Self.hex(deviceToken)
        Task {
            do {
                try await HubClient.shared.registerForPush(token: hex, environment: Self.apsEnvironment)
                registered = true
            } catch {
                // Nothing to show and nothing to retry right now: the next
                // launch calls enable() again, and iOS re-issues the same
                // token without another prompt.
                registered = false
            }
        }
    }

    /// HEX, BY HAND. `deviceToken.description` used to print the bytes and has
    /// printed "32 bytes" since iOS 13 - code that shipped the description
    /// registered a device token of literally that string, which the hub
    /// stores happily and Apple then rejects forever. There is no warning
    /// anywhere on that path, which is why this is a named function with a
    /// test rather than one line inside the callback.
    nonisolated static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Which APNs environment this BUILD's device tokens live in.
    ///
    /// READ OFF THE EMBEDDED PROVISIONING PROFILE rather than from `#if DEBUG`,
    /// because the two are not the same question. A Release build installed
    /// with a development profile - which is how every build on this rack gets
    /// onto the phone - is still a SANDBOX token, and a `#if DEBUG` check calls
    /// it production. The hub would then push it at api.push.apple.com, get a
    /// 400 BadDeviceToken, and delete the registration as dead: a
    /// misconfiguration that erases its own evidence. See hub/push.js.
    nonisolated static var apsEnvironment: String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let raw = try? Data(contentsOf: url)
        else {
            // No profile at all: the Simulator, or an App Store build. Neither
            // can be wrong in a way that matters - the Simulator gets no real
            // token, and an App Store build is production by definition but
            // will never be produced by this repo.
            return "sandbox"
        }
        // The file is a CMS envelope with a plain-text plist inside it. Slicing
        // the plist out is what every tool that reads these does; parsing CMS
        // to get at a string Apple embeds in the clear is not worth a
        // dependency.
        guard let start = raw.range(of: Data("<plist".utf8)),
            let end = raw.range(of: Data("</plist>".utf8))
        else { return "sandbox" }
        let plist = raw[start.lowerBound..<end.upperBound]
        guard let parsed = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
            let entitlements = parsed["Entitlements"] as? [String: Any],
            let aps = entitlements["aps-environment"] as? String
        else { return "sandbox" }
        // Apple spells the development value "development"; the hub speaks in
        // Apple's HOST names, where the same thing is called sandbox.
        return aps == "production" ? "production" : "sandbox"
    }
}

extension PushRegistrar: UNUserNotificationCenterDelegate {
    /// A banner while the app is already open.
    ///
    /// SHOWN, NOT SUPPRESSED, and the hub is what makes that correct rather
    /// than noisy. `notifyTurnFinished` in hub/server.js bails out while the
    /// turn still has a subscriber, so the answer being streamed on screen
    /// never produces one of these. Anything that does arrive here is therefore
    /// about a turn this app is NOT watching - the thread left running when the
    /// drawer opened another one, which is the exact case `hub/turns.js` was
    /// built for. Suppressing it because the app happens to be open would hide
    /// the one event the user is waiting on.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Tapped. OPENS THE APP AND NOTHING MORE, on purpose.
    ///
    /// THE OBVIOUS BEHAVIOUR - open the thread the banner is about - IS NOT
    /// BUILDABLE FROM THIS PAYLOAD, and the reason is a genuine id-space
    /// mismatch rather than a missing few lines here.
    ///
    /// The payload is `{ kind: "turn", conversation: <turn id>, agent }` (see
    /// notifyTurnFinished in hub/server.js). Opening a thread means building a
    /// `ChatTarget.resuming`, which needs a `ResumeRef` of `source`/`node`/`id`
    /// - and that `id` is the AGENT-NATIVE session id, the one
    /// `/api/conversations` lists and `ClaudeView.load(transcript:)` arms
    /// `.sessionId` with. The turn id is not that id:
    ///
    ///   - For Claude it is a hub-minted `randomUUID()` (`if (id == null) { id
    ///     = randomUUID(); rememberConv(id, conv) }` on the /api/claude route),
    ///     which is precisely what `Attach.conversation` documents as a
    ///     different key from `Attach.sessionId`. The mapping back to the
    ///     session id on disk lives only in the hub's in-memory `claudeConvs`
    ///     map and is exposed by no endpoint, so this app cannot resolve it.
    ///   - For Hermes the turn id HAPPENS to be the session id, but the only
    ///     other thing in the payload is `agent`, which for that route is the
    ///     display string `"Hermes · calypso"`. Recovering `node` by splitting
    ///     a human-facing label - and getting a thread open for Hermes while
    ///     Claude, the agent most of these banners are about, still could not -
    ///     is worse than doing nothing, because it looks like the feature works.
    ///
    /// Neither is guessable, and opening SOME conversation (the newest, or the
    /// last one viewed) would be a lie: the tap would land on a thread that is
    /// not the one that just finished, with nothing to tell the two apart.
    ///
    /// WHAT WOULD MAKE IT POSSIBLE, in one hub-side change: have
    /// notifyTurnFinished send the three fields a `ResumeRef` is made of -
    /// `source`, `node`, and the agent-native session id - beside the turn id.
    /// Both routes already hold all three at the call site (`conv.sessionId`
    /// for Claude, `sessionId` and `target.node` for Hermes). With those in the
    /// payload this handler becomes a `ChatTarget.resuming` pushed through a
    /// seam like `ChatHandle` - which is the pattern this repo already uses to
    /// reach the on-screen chat from outside `ChatShell`'s `@State`, and the
    /// place to put it rather than inventing a second mechanism.
    ///
    /// Until then the tap does what iOS does for free: foregrounds the app onto
    /// a chat, one hamburger tap from the thread in the drawer.
    // COMPLETION-HANDLER FORM, NOT `async`, ON PURPOSE. The nonisolated async
    // form finishes on a background executor, so the @objc thunk calls iOS's
    // completion handler off the main thread and UIKit aborts in
    // _updateSnapshotAndStateRestorationWithAction (crash logs 09-15..09-28):
    // every notification tap killed the app instead of opening it. The
    // delegate is called on the main thread; completion goes back there too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        nonisolated(unsafe) let done = completionHandler
        // Turn banners: deliberately nothing, for the reasons above.
        //
        // MAIL IS THE EXCEPTION, because its payload carries the one id it
        // needs: { kind: "mail_pending", id }. Cancel withdraws that pending
        // email; a plain tap just opens the app, where the card is. There is
        // no Send action to handle (see enable()).
        let info = response.notification.request.content.userInfo
        // mail_pending = an email; approval_pending = a text or calendar change.
        let kind = info["kind"] as? String
        guard kind == "mail_pending" || kind == "approval_pending", let id = info["id"] as? String,
              response.actionIdentifier == "MAIL_CANCEL"
        else { DispatchQueue.main.async { done() }; return }
        // Completion waits for the cancel: iOS keeps a background launch alive
        // only until it is called, so the send must finish first.
        Task { @MainActor in
            await Self.cancelMail(id)
            done()
        }
    }

    @MainActor private static func cancelMail(_ id: String) async {
        let store = MailApprovals.shared
        await store.refresh()
        guard let item = store.pending.first(where: { $0.id == id }) else { return }
        _ = await store.cancel(item)
    }
}

/// The two UIApplicationDelegate callbacks APNs needs, bridged into SwiftUI.
///
/// A DELEGATE IS UNAVOIDABLE. SwiftUI has no equivalent of
/// `didRegisterForRemoteNotificationsWithDeviceToken` - it is the one part of
/// remote notifications with no modern replacement, so `@UIApplicationDelegateAdaptor`
/// is the supported way in rather than a legacy hangover.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in PushRegistrar.shared.received(deviceToken: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Airplane mode, no APNs reachability, a profile without the
        // entitlement. None of them is actionable from inside the app, and all
        // of them resolve themselves on a later launch.
        print("[push] registration failed: \(error.localizedDescription)")
    }
}
