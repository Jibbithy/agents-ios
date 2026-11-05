// AgentsWidgets/AtlasControl.swift
import AppIntents
import SwiftUI
import WidgetKit

/// Talk to Atlas as a control: assign it to the Action Button (Settings >
/// Action Button > Controls), add it to Control Center, or put it on the lock
/// screen. All three run `ListenIntent` without opening the app.
struct AtlasControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.example.agents.talk") {
            ControlWidgetButton(action: ListenIntent()) {
                Label("Talk to Atlas", systemImage: "waveform")
            }
        }
        .displayName("Talk to Atlas")
        .description("Ask Atlas out loud. Works on a locked phone.")
    }
}
