import SwiftUI
import UIKit
import UserNotifications

/// Every chat with a turn in flight - on screen, behind the drawer, or the
/// voice chat with no view at all - and the two things the app does for all
/// of them at once when it leaves the screen and comes back.
///
/// THE TURN RUNS ON ATLAS, NOT ON THE PHONE. `hub/turns.js` keeps generating
/// and buffers whatever the socket saw or missed, so leaving the app never
/// stops an answer. What it used to cost was TIME: iOS suspends a backgrounded
/// app within seconds and its socket dies with it, and on the way back the
/// chat learned that only when URLSession gave up on the dead stream - up to
/// thirty seconds of idle - and then slept a backoff before re-attaching. That
/// was the "Reconnecting…" on every return. Two things about it:
///
///   1. ON THE WAY OUT, ask iOS for background time while any turn is live. A
///      short switch to another app, or a glance at the lock screen, then
///      never drops the socket at all: the answer keeps rendering into the
///      transcript for as long as iOS allows, about thirty seconds.
///   2. ON THE WAY BACK, if the app was actually backgrounded, re-attach every
///      live turn at once from the last event it rendered - no waiting for
///      the old socket to be declared dead, no backoff, and no "Reconnecting…"
///      unless that immediate re-attach itself fails.
///   3. WHEN THE TIME RUNS OUT, close every live socket cleanly (`detach`)
///      before iOS freezes the app. A frozen app's kernel goes on
///      acknowledging the hub's heartbeats, so without this the hub counts a
///      watcher for a turn nobody is watching - and its "finished" push,
///      which bails while anyone is watching, never comes. And a turn that
///      finishes INSIDE the thirty seconds, with the app still connected,
///      gets a local notification instead: the hub will not push for it.
///
/// Not while a voice session is running: audio keeps the app alive past the
/// thirty seconds, and a detached voice turn would leave the session waiting
/// on an answer that is parked until someone opens the app.
///
/// `ChatModel.run` registers here for the length of a turn, so a chat left
/// running behind the drawer is resumed the same way as the one on screen.
@MainActor
final class LiveTurns {
    static let shared = LiveTurns()

    /// STRONG, on purpose: a running turn's `Task` holds its model anyway, and
    /// the registration ends on the same `defer` that ends the turn.
    private(set) var models: [ObjectIdentifier: ChatModel] = [:]

    /// Set on `.background`, so that a mere `.inactive` blip - the notification
    /// shade, a Face ID sheet, the app switcher glanced at and dismissed - does
    /// not tear down a stream that is still perfectly alive.
    private var backgrounded = false

    private var task: UIBackgroundTaskIdentifier?

    /// The two UIApplication calls, as values so a test can drive this without
    /// an app. `begin` is handed the expiry handler and returns the handle
    /// `end` takes, or `.invalid` when iOS refuses.
    typealias Begin = @MainActor (_ expired: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    typealias End = @MainActor (UIBackgroundTaskIdentifier) -> Void
    /// A local "finished" notification: identifier, title, body. The identifier
    /// is the hub's collapse id for the same turn, so a later push about it
    /// replaces this rather than stacking.
    typealias Notify = @MainActor (_ id: String, _ title: String, _ body: String) -> Void
    private let begin: Begin
    private let end: End
    private let notify: Notify
    /// Whether the app is being kept alive by something other than this - a
    /// voice session - so that expiring background time is not the freeze it
    /// otherwise means.
    private let voiceLive: @MainActor () -> Bool

    init(
        begin: @escaping Begin = { expired in
            UIApplication.shared.beginBackgroundTask(withName: "agents.turn") {
                MainActor.assumeIsolated { expired() }
            }
        },
        end: @escaping End = { UIApplication.shared.endBackgroundTask($0) },
        notify: @escaping Notify = LiveTurns.localNotification,
        voiceLive: @escaping @MainActor () -> Bool = { VoiceSession.shared.isActive || AtlasVoice.shared.answering }
    ) {
        self.begin = begin
        self.end = end
        self.notify = notify
        self.voiceLive = voiceLive
    }

    /// A turn started. One that starts while the app is already in the
    /// background - the voice chat asked from the lock screen - needs the
    /// background time just as much as one that was running when it went.
    func began(_ model: ChatModel) {
        models[ObjectIdentifier(model)] = model
        if backgrounded { keepAlive() }
    }

    /// A turn ended, however it ended. The last one out gives the background
    /// time back, rather than holding it until iOS takes it.
    func ended(_ model: ChatModel) {
        models[ObjectIdentifier(model)] = nil
        if models.isEmpty { letGo() }
    }

    /// A turn landed its `done`. Away from the screen that is the ping - the
    /// hub only pushes for a turn nobody was watching, and for the first
    /// thirty seconds this app still was. On screen there is nothing to say.
    func finished(_ model: ChatModel) {
        guard backgrounded, let id = model.threadId else { return }
        let answer = model.bubbles.last(where: { $0.kind == .assistant })?.text ?? ""
        let body = answer.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        notify(
            "turn:\(id)", "\(model.agent.deckName) finished",
            body.isEmpty ? "Tap to read the answer." : String(body.prefix(180)))
    }

    func scene(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgrounded = true
            if !models.isEmpty { keepAlive() }
        case .active:
            let wasAway = backgrounded
            backgrounded = false
            letGo()
            if wasAway { for model in models.values { model.resumeIfLive() } }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func keepAlive() {
        guard task == nil else { return }
        // THE EXPIRY HANDLER MUST END THE TASK, or iOS kills the app for
        // overrunning; `letGo` is that, and is also what the last turn ending
        // and the app coming back both call.
        let id = begin { [weak self] in self?.expired() }
        if id != .invalid { task = id }
    }

    /// Background time is up: the app is about to be frozen. Hang up every
    /// live turn cleanly so the hub knows, then give the time back.
    private func expired() {
        if !voiceLive() { for model in models.values { model.detach() } }
        letGo()
    }

    private static func localNotification(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["kind": "turn", "conversation": id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func letGo() {
        guard let id = task else { return }
        task = nil
        end(id)
    }
}
