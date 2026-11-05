// Agents/Voice/VoiceActivity.swift
import ActivityKit
import Foundation
import os

/// Starts, updates and ends the Live Activity from the session's phases.
///
/// ENDS WITH A DWELL, not at once: the last thing shown - the answer's first
/// lines, or "Mic busy." - stays on the lock screen for a few seconds, which
/// on a locked phone is the only place it can be read.
@MainActor
final class VoiceActivity {
    static let shared = VoiceActivity()

    /// The user swiped the activity away mid-session. The system likely stops
    /// a background recording with no Live Activity up, so the session should
    /// stop too rather than listen to nothing.
    var onDismissed: (() -> Void)?

    /// How long what the activity shows is good for without an update. Every
    /// phase change pushes it on; one stranded by a killed app goes stale and
    /// greys out, rather than saying "Thinking…" as if it still were.
    static let staleAfter: TimeInterval = 10 * 60

    private var activity: Activity<VoiceActivityAttributes>?
    /// What the activity shows now, kept so it can end on it.
    private var last: ActivityContent<VoiceActivityAttributes.ContentState>?
    /// This session's request failed; don't ask again until it ends. Without
    /// it every phase after - each partial transcript, several a second -
    /// would ask again and log again.
    private var requestFailed = false

    func show(_ phase: VoicePhase) {
        // STAMPED HERE, IN PHASE ORDER. `update` runs off the main actor, so
        // the tasks below can reach the system in any order; the system drops
        // an update older than the last one it took, so the newest phase wins.
        let at = Date.now
        guard !phase.isIdle else {
            end(at)
            return
        }
        let content = ActivityContent(state: phase.content, staleDate: at + Self.staleAfter)
        if let activity {
            last = content
            let id = activity.id
            Task { await Self.running(id)?.update(content, alertConfiguration: nil, timestamp: at) }
        } else if !requestFailed {
            start(content)
        }
    }

    /// Takes down every voice activity at once, this session's or not. The
    /// Cancel button on one iOS left behind when it killed the app mid-turn:
    /// the relaunched app has an idle session, and nothing else would end it.
    func endAll() {
        activity = nil
        last = nil
        Self.endNow(Activity<VoiceActivityAttributes>.activities.map(\.id))
    }

    private func start(_ content: ActivityContent<VoiceActivityAttributes.ContentState>) {
        // LEFTOVERS GO FIRST: one orphaned by a killed app, still saying
        // "Thinking…", or the last session's dwell, which would otherwise
        // stack under this one. Their ids are taken before `request`, so the
        // new activity is never among them.
        Self.endNow(Activity<VoiceActivityAttributes>.activities.map(\.id))
        do {
            let started = try Activity.request(attributes: VoiceActivityAttributes(), content: content)
            activity = started
            last = content
            watch(started.id)
        } catch {
            // Fails with Live Activities turned off for Agents. From the
            // composer, voice still works with nowhere to show itself; from
            // `ListenIntent` in the background the system stops the recording,
            // which is why that intent checks first. Logged so a device run
            // shows the real reason.
            Logger.voice.error("Live Activity request failed: \(String(describing: error), privacy: .public)")
            requestFailed = true
        }
    }

    private func end(_ at: Date) {
        requestFailed = false
        guard let activity else { return }
        let id = activity.id
        let last = self.last
        self.activity = nil
        self.last = nil
        Task { await Self.running(id)?.end(last, dismissalPolicy: .after(at + 4), timestamp: at) }
    }

    /// Swiped away while it is still this session's: drop it and say so. One
    /// this class ended itself is no longer `activity` by the time its
    /// dismissal arrives, so that is ignored.
    private func watch(_ id: Activity<VoiceActivityAttributes>.ID) {
        Task {
            guard await Self.dismissed(id), activity?.id == id else { return }
            activity = nil
            last = nil
            onDismissed?()
        }
    }

    /// BY ID, NOT BY THE STORED REFERENCE. `Activity` is not Sendable, so
    /// Swift 6 will not let the main actor hand its copy to `update` and `end`,
    /// which run off it; one looked up here belongs to no actor and can go.
    private nonisolated static func running(_ id: Activity<VoiceActivityAttributes>.ID) -> Activity<VoiceActivityAttributes>? {
        Activity<VoiceActivityAttributes>.activities.first { $0.id == id }
    }

    /// Waits for the activity to be dismissed. False if it is already gone.
    private nonisolated static func dismissed(_ id: Activity<VoiceActivityAttributes>.ID) async -> Bool {
        guard let activity = running(id) else { return false }
        for await state in activity.activityStateUpdates where state == .dismissed {
            return true
        }
        return false
    }

    private nonisolated static func endNow(_ ids: [Activity<VoiceActivityAttributes>.ID]) {
        guard !ids.isEmpty else { return }
        Task {
            for id in ids { await running(id)?.end(nil, dismissalPolicy: .immediate) }
        }
    }
}

extension VoicePhase {
    /// How much of the line the Live Activity carries. ActivityKit refuses an
    /// update over 4 KB, and a whole answer can be more than that; the lock
    /// screen shows three lines or so of it anyway.
    static let activityDetailLimit = 240

    var content: VoiceActivityAttributes.ContentState {
        .init(label: label, detail: activityDetail, symbol: symbol)
    }

    /// `detail`, cut to `activityDetailLimit`: the NEWEST words while
    /// listening, which is what you are checking the phone for, and the start
    /// of anything read.
    private var activityDetail: String {
        let text = detail
        guard text.count > Self.activityDetailLimit else { return text }
        if isListening { return "…" + text.suffix(Self.activityDetailLimit) }
        return text.prefix(Self.activityDetailLimit) + "…"
    }
}
