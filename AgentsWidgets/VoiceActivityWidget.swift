// AgentsWidgets/VoiceActivityWidget.swift
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Listening → Thinking → the answer, in the Dynamic Island and on the lock
/// screen. System fonts and colours on purpose: the Deck faces and palette live
/// in the app target, and the island is black whatever the theme.
///
/// GREYED WHEN STALE: ten minutes without an update (`VoiceActivity.staleAfter`)
/// is an activity a killed app left behind, and what it says is no longer so.
struct VoiceActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
            VoiceActivityRow(state: context.state, stale: context.isStale)
                .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.symbol).font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.label).font(.headline)
                        .opacity(context.isStale ? 0.5 : 1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: CancelVoiceIntent()) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel voice")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.detail).font(.body).lineLimit(3)
                        .opacity(context.isStale ? 0.5 : 1)
                }
            } compactLeading: {
                Image(systemName: context.state.symbol)
            } compactTrailing: {
                Text(context.state.label).font(.caption)
            } minimal: {
                Image(systemName: context.state.symbol)
            }
        }
    }
}

struct VoiceActivityRow: View {
    let state: VoiceActivityAttributes.ContentState
    var stale = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                Image(systemName: state.symbol).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.label).font(.headline)
                    Text(state.detail).font(.body).lineLimit(3)
                }
            }
            // Cancel stays at full strength: on a stale activity it is the
            // way to take it down.
            .opacity(stale ? 0.5 : 1)
            Spacer(minLength: 0)
            Button(intent: CancelVoiceIntent()) {
                Image(systemName: "xmark.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel voice")
        }
    }
}
