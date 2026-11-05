import SwiftUI

/// "THINKING… · 12S" with three pulsing blocks, shown at the foot of the
/// transcript for exactly as long as a turn is in flight.
///
/// WHY THIS EXISTS AT ALL. Before it, the only sign a turn was running was the
/// composer's placeholder changing to "Still answering…" - a grey string at the
/// very bottom of the screen, below the keyboard's old position, on a control
/// the user has just stopped looking at. A long Claude turn is minutes of
/// nothing happening where the ANSWER is going to appear, which is
/// indistinguishable from a send that never left the phone. The dots are not
/// decoration; they are the only thing on screen that says the request landed.
struct ThinkingRow: View {
    /// When the turn started. The elapsed count is derived from this rather
    /// than ticked up in a counter, so it stays truthful across the thing this
    /// app is built around: the phone being locked. Timers do not fire while
    /// iOS has the app suspended, so a counter would come back reading the time
    /// spent WATCHING rather than the time the turn has been running.
    let startedAt: Date
    /// True while the turn is running but nothing is attached to it. Same
    /// distinction the composer's placeholder makes - see `ChatModel`.
    let reconnecting: Bool

    var body: some View {
        HStack(spacing: Theme.sp3) {
            ThinkingDots()
            // TIMELINEVIEW WRAPS THE TEXT ONLY, not the whole row. It rebuilds
            // its body every second, and a `repeatForever` animation inside a
            // view that is rebuilt on a schedule is a coin flip - the dots
            // stutter or stop. Scoped here, the dots are a sibling that nothing
            // re-evaluates.
            TimelineView(.periodic(from: startedAt, by: 1)) { ctx in
                // A Deck label - Plex Mono, uppercase, muted. Mono is also what
                // keeps the seconds a fixed width as they tick; without that
                // the whole row shuffles left and right once a second.
                Text(label(at: ctx.date))
                    .deckLabel()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.sp1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(at: Date()))
    }

    private func label(at now: Date) -> String {
        let word = reconnecting ? "Reconnecting" : "Thinking"
        return "\(word)… · \(Elapsed.label(now.timeIntervalSince(startedAt)))"
    }
}

/// How long a turn has been running, as a string.
///
/// A free enum rather than a method on the view above, and nonisolated, so the
/// one part of this row that has a right and a wrong answer can be tested
/// without a simulator or a MainActor hop.
enum Elapsed {
    static func label(_ seconds: TimeInterval) -> String {
        // NEGATIVE IS REACHABLE, not paranoia: `startedAt` is stamped on the
        // phone and the row's first render can land microseconds before it if
        // the clock is adjusted mid-turn. "-1s" reads as a bug.
        let total = Int(max(0, seconds))
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(String(format: "%02d", total % 60))s"
    }
}

/// Three square blocks, pulsing out of phase - Deck has no circles to pulse.
///
/// REDUCE MOTION GETS THEM AT FULL BRIGHTNESS, not dimmed and still. The
/// obvious implementation leaves the un-animated state at the trough of the
/// pulse, so the accessibility setting turns a live indicator into three pale
/// blocks that look like a control that has failed.
private struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Rectangle()
                    .fill(Deck.ink)
                    .frame(width: 7, height: 7)
                    .opacity(reduceMotion ? 1 : (pulsing ? 1 : 0.22))
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.18),
                        value: pulsing)
            }
        }
        // ONE FLIP, ON APPEAR. `repeatForever` needs a value CHANGE to start
        // from; setting `pulsing` in an initialiser gives it nothing to
        // animate and the dots sit still forever.
        .onAppear { pulsing = true }
        .accessibilityHidden(true)
    }
}
