// Agents/Voice/Endpointer.swift
import Foundation

/// When a spoken question is over.
///
/// MEASURED FROM WORDS, NOT FROM AUDIO LEVELS. `heard(at:)` is fed every time
/// the recogniser's transcript changes, so a quiet speaker in a loud car is
/// still "talking" for as long as words keep arriving - and a level meter
/// would cut exactly that person off.
struct Endpointer {
    enum Ending: Equatable { case spoke, silent }

    /// Quiet after the last new word before the question counts as asked.
    static let pause: TimeInterval = 1.5
    /// How long to wait for a first word before ending quietly.
    static let noSpeech: TimeInterval = 5

    let started: Date
    /// Waits for a first word for as long as it takes: the `noSpeech` clock
    /// does not run. THE LISTEN OVER AN ANSWER, which is open for however
    /// long Atlas talks and must not give up in the middle of it. Only
    /// whoever started it ends it - see `VoiceSession`.
    let patient: Bool
    private(set) var lastWord: Date?

    init(started: Date, patient: Bool = false) {
        self.started = started
        self.patient = patient
    }

    mutating func heard(at time: Date) { lastWord = time }

    func ending(at now: Date) -> Ending? {
        if let lastWord { return now.timeIntervalSince(lastWord) >= Self.pause ? .spoke : nil }
        guard !patient else { return nil }
        return now.timeIntervalSince(started) >= Self.noSpeech ? .silent : nil
    }
}
