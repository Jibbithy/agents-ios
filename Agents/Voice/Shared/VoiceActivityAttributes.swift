// Agents/Voice/Shared/VoiceActivityAttributes.swift
import ActivityKit

/// The Live Activity's data. SHARED WITH THE WIDGET EXTENSION, which draws it,
/// so this file must compile there too - no app-only types.
struct VoiceActivityAttributes: ActivityAttributes {
    /// Plain strings, not `VoicePhase`: the extension cannot see that type, and
    /// the activity only ever needs what the phase already says in words.
    struct ContentState: Codable, Hashable {
        var label: String
        var detail: String
        var symbol: String
    }
}
