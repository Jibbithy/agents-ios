// Agents/Voice/Cues.swift
import Foundation

/// The session's non-verbal sounds: a chime as the mic reopens, one as a
/// conversation ends.
enum Cue: Sendable, CustomStringConvertible {
    case listening, ending

    var description: String {
        switch self {
        case .listening: "listening"
        case .ending: "ending"
        }
    }
}

/// The sounds, from the session's side. `AudioSessionVoice` in the app, a
/// recording fake in tests.
@MainActor protocol VoiceCues: AnyObject {
    /// Plays `cue` and returns once it has been HEARD, so a listen opened
    /// after it cannot transcribe it. Returns at once with nothing to play on.
    func play(_ cue: Cue) async
    /// The soft loop while Atlas thinks. Idempotent. The real one also stops
    /// itself at the first buffer of speech - see `VoiceOutput.schedule`.
    func thinking(_ on: Bool)
}

/// The cues' audio, made here rather than shipped: no licensed assets, and
/// nothing to bundle. Mono float at `VoiceOutput.rate`, the format every
/// voice already plays in on the one engine.
///
/// QUIET ON PURPOSE. They play in the same ducking session as Atlas's voice,
/// often into AirPods, and a chime as loud as speech is startling. Every
/// sound starts and ends at silence, so none clicks - and the thinking loop
/// can repeat with no seam.
enum CueSynth {
    static let rate = VoiceOutput.rate

    static func samples(for cue: Cue) -> [Float] {
        switch cue {
        // Rising: "go ahead". A fifth up, two short soft notes.
        case .listening: notes([(660, 0.075), (990, 0.1)], peak: 0.18)
        // Falling: "done".
        case .ending: notes([(880, 0.09), (587, 0.16)], peak: 0.16)
        }
    }

    /// A slow swell and fade of two low sines, about 1.6 s, peaking quietly:
    /// a breath rather than a beep, for however long Claude takes. Its
    /// envelope is zero at both ends, so looped it has no seam.
    static func thinkingLoop() -> [Float] {
        let count = Int(rate * 1.6)
        return (0..<count).map { i in
            let t = Double(i) / rate
            let x = Double(i) / Double(count - 1)
            let envelope = 0.5 - 0.5 * cos(2 * .pi * x)
            let tone = 0.7 * sin(2 * .pi * 220 * t) + 0.3 * sin(2 * .pi * 330 * t)
            return Float(0.045 * envelope * envelope * tone)
        }
    }

    /// Notes one after another, each with a short raised-cosine fade in and
    /// out so neither end clicks.
    private static func notes(_ notes: [(hz: Double, seconds: Double)], peak: Double) -> [Float] {
        var out: [Float] = []
        for note in notes {
            let count = Int(rate * note.seconds)
            let fade = max(1, Int(rate * 0.012))
            for i in 0..<count {
                let t = Double(i) / rate
                let edge = min(i, count - 1 - i)
                let gain = edge >= fade ? 1 : 0.5 - 0.5 * cos(.pi * Double(edge) / Double(fade))
                out.append(Float(peak * gain * sin(2 * .pi * note.hz * t)))
            }
        }
        return out
    }
}
