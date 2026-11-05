// Agents/Voice/WakeGate.swift
import Foundation

/// When "Hey Atlas" may listen. A function of its own because all three
/// conditions are easy to drop one of, and dropping the last one is how the
/// app ends up answering itself.
enum WakeGate {
    static func listens(enabled: Bool, active: Bool, idle: Bool) -> Bool {
        enabled && active && idle
    }
}
