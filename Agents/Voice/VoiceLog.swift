// Agents/Voice/VoiceLog.swift
import Foundation
import UIKit
import os

extension Logger {
    /// Everything voice logs: the session, the mic, the recogniser, the Live
    /// Activity and "Hey Atlas". ONE CATEGORY, so a device run filtered to it
    /// in Console reads as one story, in order.
    static let voice = Logger(subsystem: "com.example.agents", category: "voice")
    /// What the pending-approval store logs: a fetch that failed, an item it
    /// could not decode. Read next to `voice` when a read-back that should
    /// have happened did not.
    static let mail = Logger(subsystem: "com.example.agents", category: "mail")
}

extension VoicePhase {
    /// The phase for the log: which one, the tool running, and a failure's
    /// words. NEVER WHAT WAS HEARD OR THE ANSWER - those are the user's, and a
    /// log can be read by anyone with the phone on a Mac.
    var logged: String {
        switch self {
        case .idle: "idle"
        case .listening: "listening"
        case .thinking(let tool): tool.map { "thinking (\($0))" } ?? "thinking"
        case .speaking: "speaking"
        case .failed(let message): "failed: \(message)"
        }
    }
}

extension Error {
    /// "domain code": what an AVAudioSession or Speech error is looked up by.
    /// An audio session's code is a four-character OSStatus - 560030580 is
    /// '!act', "is busy" - which its description does not say.
    var domainAndCode: String {
        let error = self as NSError
        return "\(error.domain) \(error.code)"
    }
}

extension UIApplication.State {
    var logged: String {
        switch self {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}
