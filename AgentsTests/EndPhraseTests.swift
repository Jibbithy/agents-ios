// AgentsTests/EndPhraseTests.swift
import XCTest

@testable import Agents

final class EndPhraseTests: XCTestCase {
    private let phrases = VoiceSettings.defaultEndPhrases

    private func ends(_ heard: String, _ phrases: [String]? = nil) -> Bool {
        EndPhrase.matches(heard, phrases: phrases ?? self.phrases)
    }

    func testTheDefaultsEndWholeUtterances() {
        XCTAssertTrue(ends("that's all"))
        XCTAssertTrue(ends("That's all."))
        XCTAssertTrue(ends("Goodbye, Atlas!"))
        XCTAssertTrue(ends("Thanks Atlas, that's it."))
    }

    func testDismissedEndsIt() {
        XCTAssertTrue(ends("Dismissed."))
        XCTAssertTrue(ends("ok, dismissed"))
        XCTAssertFalse(ends("was the meeting dismissed?"))
        XCTAssertFalse(ends("the case was dismissed yesterday and I need to email the lawyer"))
    }

    func testCaseApostrophesAndPunctuationAreFolded() {
        XCTAssertTrue(ends("THATS ALL"))
        XCTAssertTrue(ends("That\u{2019}s all"))
        XCTAssertTrue(ends("thanks, atlas - that's it"))
    }

    /// The recogniser and the settings do not have to agree on spelling.
    func testAliasesAreFoldedOnBothSides() {
        XCTAssertTrue(ends("That is all."))
        XCTAssertTrue(ends("Good bye Atlas."))
        XCTAssertTrue(ends("Thank you Atlas, that's it."))
    }

    func testAShortLeadInStillEnds() {
        XCTAssertTrue(ends("ok that's all"))
        XCTAssertTrue(ends("Okay, great, that's all."))
        XCTAssertTrue(ends("alright then goodbye Atlas"))
    }

    /// THE WHOLE POINT OF "TRAILING": the phrase inside a real question is a
    /// question, and must go to Atlas.
    func testThePhraseInsideAQuestionDoesNotEnd() {
        XCTAssertFalse(ends("is that all the mail?"))
        XCTAssertFalse(ends("Is that all the mail"))
        XCTAssertFalse(ends("that's all?"), "asked, not said")
        XCTAssertFalse(ends("what's all this about"))
    }

    /// A request that happens to end in the phrase is a request.
    func testALongRequestEndingInThePhraseDoesNotEnd() {
        XCTAssertFalse(ends("read me the first three emails, that's all"))
    }

    func testOtherWordsDoNotEnd() {
        XCTAssertFalse(ends("send"))
        XCTAssertFalse(ends("send it"))
        XCTAssertFalse(ends("all"))
        XCTAssertFalse(ends(""))
        XCTAssertFalse(ends("   "))
        XCTAssertFalse(ends("goodbye"), "not a default on its own")
    }

    func testCustomPhrases() {
        XCTAssertTrue(ends("ok stop listening", ["stop listening"]))
        XCTAssertFalse(ends("that's all", ["stop listening"]))
    }

    /// A blank phrase in the settings must not match everything.
    func testABlankPhraseMatchesNothing() {
        XCTAssertFalse(ends("hello", ["", "   ", "..."]))
        XCTAssertFalse(ends("", [""]))
    }
}

final class SilenceWatchTests: XCTestCase {
    func testTheFirstSilentListenChimesAndLaterOnesDoNot() {
        var watch = SilenceWatch(limit: 25, maxListens: 8)
        XCTAssertEqual(watch.heardNothing(listenStarted: 0, now: 5), .listenAgain(chime: true))
        XCTAssertEqual(watch.heardNothing(listenStarted: 5, now: 10), .listenAgain(chime: false))
    }

    /// Measured from the start of the FIRST silent listen, not the last.
    func testEndsOnceTheSilenceHasLastedTheLimit() {
        var watch = SilenceWatch(limit: 25, maxListens: 8)
        var t: TimeInterval = 100
        for _ in 0..<4 {
            XCTAssertNotEqual(watch.heardNothing(listenStarted: t, now: t + 5), .end)
            t += 5
        }
        XCTAssertEqual(watch.heardNothing(listenStarted: t, now: t + 5), .end)
    }

    /// Words start the count over.
    func testWordsResetTheSilence() {
        var watch = SilenceWatch(limit: 25, maxListens: 8)
        _ = watch.heardNothing(listenStarted: 0, now: 20)
        watch.heardWords()
        XCTAssertEqual(watch.heardNothing(listenStarted: 30, now: 35), .listenAgain(chime: true))
        XCTAssertEqual(watch.heardNothing(listenStarted: 35, now: 50), .listenAgain(chime: false))
        XCTAssertEqual(watch.heardNothing(listenStarted: 50, now: 55), .end)
    }

    /// A listener that returns at once, over and over (a recogniser failing
    /// quietly), must not spin for the whole limit.
    func testTooManySilentListensEndEvenIfQuick() {
        var watch = SilenceWatch(limit: 25, maxListens: 3)
        XCTAssertNotEqual(watch.heardNothing(listenStarted: 0, now: 0.1), .end)
        XCTAssertNotEqual(watch.heardNothing(listenStarted: 0.1, now: 0.2), .end)
        XCTAssertEqual(watch.heardNothing(listenStarted: 0.2, now: 0.3), .end)
    }
}

final class VoiceSettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "VoiceSettingsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaultsAreContinuousWithTheFourPhrases() {
        let s = VoiceSettings.load(from: defaults())
        XCTAssertTrue(s.continuous)
        XCTAssertEqual(s.endPhrases, ["dismissed", "that's all", "goodbye Atlas", "thanks Atlas, that's it"])
    }

    func testRoundTrip() {
        let d = defaults()
        VoiceSettings(continuous: false, endPhrases: ["over and out"]).save(to: d)
        XCTAssertEqual(VoiceSettings.load(from: d), VoiceSettings(continuous: false, endPhrases: ["over and out"]))
    }

    /// Blank lines from the editor are dropped; an all-blank list falls back
    /// to the defaults rather than leaving no way to end by voice.
    func testPhrasesFromTextDropBlanksAndNeverEndEmpty() {
        XCTAssertEqual(VoiceSettings.phrases(from: " over and out \n\n  that's all\n"), ["over and out", "that's all"])
        XCTAssertEqual(VoiceSettings.phrases(from: "\n  \n"), VoiceSettings.defaultEndPhrases)
    }
}

final class CueSynthTests: XCTestCase {
    func testEveryCueIsShortQuietAndStartsAndEndsAtZero() {
        for cue in [Cue.listening, .ending] {
            let s = CueSynth.samples(for: cue)
            XCTAssertGreaterThan(s.count, 0)
            XCTAssertLessThan(Double(s.count) / CueSynth.rate, 0.5, "\(cue) is a blip, not a tune")
            XCTAssertLessThanOrEqual(s.map(abs).max() ?? 1, 0.3)
            XCTAssertEqual(s.first ?? 1, 0, accuracy: 0.001)
            XCTAssertEqual(s.last ?? 1, 0, accuracy: 0.01)
        }
    }

    /// Looped, so it must begin and end at silence (no click at the seam),
    /// and it must be soft.
    func testTheThinkingLoopIsSoftAndSeamless() {
        let s = CueSynth.thinkingLoop()
        XCTAssertGreaterThan(Double(s.count) / CueSynth.rate, 0.8)
        XCTAssertLessThanOrEqual(s.map(abs).max() ?? 1, 0.08)
        XCTAssertGreaterThan(s.map(abs).max() ?? 0, 0.005, "audible at all")
        XCTAssertEqual(s.first ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(s.last ?? 1, 0, accuracy: 0.002)
    }
}
