// AgentsTests/VoiceConversationTests.swift
import XCTest

@testable import Agents

/// The cues, recorded in order alongside every listen that starts (the
/// listener's `onListen` writes "listen" into the same log).
@MainActor final class FakeCues: VoiceCues {
    private(set) var log: [String] = []
    /// Called mid-chime, so a test can press while one plays.
    var duringChime: (() -> Void)?
    private(set) var isThinking = false

    func play(_ cue: Cue) async {
        log.append("\(cue)")
        if cue == .listening, let during = duringChime {
            duringChime = nil
            during()
            await Task.yield()
        }
    }
    func thinking(_ on: Bool) {
        if on != isThinking { log.append(on ? "hum" : "hush") }
        isThinking = on
    }
    func listened(patient: Bool) { log.append(patient ? "listen-over" : "listen") }

    var played: [String] { log.filter { $0 == "listening" || $0 == "ending" } }
}

@MainActor
final class VoiceConversationTests: XCTestCase {
    private func until(
        _ condition: @autoclosure () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting", file: file, line: line)
    }

    /// A conversing rig whose listens each take five seconds of its clock and
    /// are logged next to the cues.
    private func rig(
        _ queue: [String?], heard: String? = nil,
        answer: AskResult = .reply("All up.")
    ) -> Rig {
        let r = Rig(heard: heard, answer: answer)
        r.converse()
        r.listener.queue = queue
        r.listener.onListen = { [unowned r] patient in
            r.cues.listened(patient: patient)
            if !patient { r.clock += 5 }
        }
        return r
    }

    // MARK: - keeps listening

    func testKeepsListeningAfterEachAnswerUntilTheEndPhrase() async {
        let r = rig(["is atlas up", "and hermes", "ok that's all"])
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, ["is atlas up", "and hermes"], "one chat, every turn")
        XCTAssertEqual(r.speaker.spoken, ["All up.", "All up."])
        XCTAssertEqual(r.listener.listens, 3)
        XCTAssertEqual(r.audio.begins, 1, "one audio session for the whole conversation")
        XCTAssertEqual(r.audio.ends, 1)
        XCTAssertEqual(r.cues.played.last, "ending")
    }

    /// Goodbye is the app's business, never Atlas's.
    func testTheEndPhraseIsNeverAsked() async {
        let r = rig(["That's all."])
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, [])
        XCTAssertEqual(r.speaker.spoken, [])
        XCTAssertEqual(r.cues.played, ["listening", "ending"])
    }

    /// Every mic reopening chimes FIRST and is only then listened to, so the
    /// recogniser never hears the chime.
    func testTheListeningChimeComesBeforeEachListen() async {
        let r = rig(["is atlas up", "that's all"])
        r.session.trigger(r.asker)
        await until(r.finished)
        let order = r.cues.log.filter { $0 == "listening" || $0 == "listen" }
        XCTAssertEqual(order, ["listening", "listen", "listening", "listen"])
    }

    /// Send pressed while the chime plays, before any listen is running: it
    /// is not lost (the listener forgets a finish between listens) - it ends
    /// that listen empty, as a press on an empty listen does.
    func testSendDuringTheChimeIsNotLost() async {
        let r = Rig()
        r.listener.holds = true
        r.cues.duringChime = { [unowned r] in r.session.press() }
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.listener.listens, 0, "no listen opened after the send")
        XCTAssertEqual(r.asker.asked, [])
    }

    // MARK: - silence

    /// A silent listen re-prompts rather than ending: listen again, chiming
    /// once, not every five seconds.
    func testSilenceListensAgainAndChimesOnce() async {
        let r = rig([nil, nil, "is atlas up", "that's all"])
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, ["is atlas up"])
        XCTAssertEqual(r.listener.listens, 4)
        let order = r.cues.log.filter { $0 == "listening" || $0 == "listen" }
        XCTAssertEqual(order, ["listening", "listen", "listening", "listen", "listen", "listening", "listen"])
    }

    func testLongSilenceEndsWithASpokenCue() async {
        let r = rig([])
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, [])
        XCTAssertEqual(r.listener.listens, 5, "25 s of five-second listens")
        XCTAssertEqual(r.speaker.said, [VoiceSession.endingForSilence])
        XCTAssertEqual(r.cues.played.last, "ending")
        XCTAssertEqual(r.audio.ends, 1)
    }

    /// The silence after an answer counts the same.
    func testSilenceAfterAnAnswerEndsToo() async {
        // The fake repeats its last word for ever; nil after is the quiet.
        let r = rig(["is atlas up", nil])
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, ["is atlas up"])
        XCTAssertEqual(r.listener.listens, 6)
        XCTAssertEqual(r.speaker.said, [VoiceSession.endingForSilence])
    }

    // MARK: - what still ends it

    /// A recogniser that fails would otherwise say so every five seconds.
    func testAFailedListenEndsTheConversation() async {
        let r = rig([])
        r.listener.error = VoiceError.speechUnavailable
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.speaker.spoken, [VoiceSession.speechUnavailable])
        XCTAssertEqual(r.listener.listens, 1)
        XCTAssertFalse(r.cues.played.contains("ending"))
    }

    /// Cancel is asking for quiet: no goodbye.
    func testCancelEndsQuietly() async {
        let r = rig(["is atlas up"])
        r.listener.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .listening(heard: "is atlas up"))
        r.session.cancel()
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, [])
        XCTAssertEqual(r.speaker.said, [])
        XCTAssertFalse(r.cues.played.contains("ending"))
    }

    /// The pencil stopped the turn: that chat is done with, and so is the
    /// conversation.
    func testAStoppedTurnEndsTheConversation() async {
        let r = rig(["is atlas up", "and hermes"], answer: .stopped)
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, ["is atlas up"])
        XCTAssertEqual(r.listener.listens, 1)
    }

    /// A failed turn is read, and the conversation goes on.
    func testAFailedTurnKeepsTheConversationGoing() async {
        let r = rig(["is atlas up", "that's all"], answer: .failed("Can't reach the rack."))
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.speaker.said, ["Can't reach the rack."])
        XCTAssertEqual(r.listener.listens, 2)
        XCTAssertEqual(r.cues.played.last, "ending")
    }

    /// Single-shot, as before: one answer, no goodbye.
    func testWithConversationOffOneAnswerEndsIt() async {
        let r = Rig()
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(r.listener.listens, 1)
        XCTAssertEqual(r.cues.played, ["listening"])
    }

    // MARK: - talking over

    /// "That's all" said over the answer stops it and ends.
    func testTalkingOverWithTheEndPhraseEnds() async {
        let r = rig(["is atlas up"], answer: .reply("Done."))
        r.audio.echoCancelled = true
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.listener.patients == 1)
        r.speaker.holds = false
        r.listener.hears("that's all")
        await until(r.session.phase == .listening(heard: "that's all"))
        r.listener.finish()
        await until(r.finished)
        XCTAssertEqual(r.asker.asked, ["is atlas up"])
        XCTAssertEqual(r.cues.played.last, "ending")
    }

    // MARK: - the thinking hum

    func testTheHumPlaysWhileThinkingAndIsOffForEveryListen() async {
        let r = rig(["is atlas up", "that's all"])
        r.asker.holds = true
        var humDuringListen = false
        r.listener.onListen = { [unowned r] patient in
            if r.cues.isThinking { humDuringListen = true }
            r.cues.listened(patient: patient)
            r.clock += 5
        }
        r.session.trigger(r.asker)
        await until(r.session.phase == .thinking(tool: nil))
        XCTAssertTrue(r.cues.isThinking)
        r.asker.release()
        await until(r.finished)
        XCTAssertFalse(humDuringListen)
        XCTAssertFalse(r.cues.isThinking)
    }

    func testCancelWhileThinkingStopsTheHum() async {
        let r = rig(["is atlas up"])
        r.asker.holds = true
        r.session.trigger(r.asker)
        await until(r.session.phase == .thinking(tool: nil))
        r.session.cancel()
        await until(r.finished)
        XCTAssertFalse(r.cues.isThinking)
    }

    /// Talking over the answer before its first audio stops the hum at once.
    func testTalkingOverStopsTheHum() async {
        let r = rig(["is atlas up"], answer: .reply("Done."))
        r.audio.echoCancelled = true
        r.speaker.holds = true
        r.session.trigger(r.asker)
        await until(r.listener.patients == 1)
        XCTAssertTrue(r.cues.isThinking, "no audio yet: the fake voice never stops it")
        r.listener.hears("what about hermes")
        await until(r.session.phase == .listening(heard: "what about hermes"))
        XCTAssertFalse(r.cues.isThinking)
        r.session.cancel()
        await until(r.finished)
    }

    // MARK: - approvals mid-conversation

    private let item = Approval(
        mail: MailPending(
            id: "p_1", hash: String(repeating: "a", count: 64), expiresAt: 1,
            message: .init(to: ["user2@example.com"], cc: [], bcc: [], subject: "Friday", body: "Running late", in_reply_to: nil)))

    func testSendStillApprovesMidConversation() async {
        let r = rig(["email alex", "send it", "that's all"], answer: .reply("Drafted it."))
        let mail = FakeMailConfirmer()
        mail.next = item
        r.session.mail = mail
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(mail.approved, ["p_1"])
        XCTAssertEqual(r.asker.asked, ["email alex"])
        XCTAssertEqual(r.speaker.spoken, [item.readBack, "Sent."], "the read-back is the answer; the reply stays in the chat")
        XCTAssertEqual(r.cues.played.last, "ending")
    }

    /// A goodbye at the read-back is a goodbye: the words are neither send
    /// nor cancel, so the proposal is cancelled and they go round as the next
    /// question, where the end phrase ends the conversation. Nothing is sent,
    /// nothing is asked of Atlas, and "Left it on screen" is not said.
    func testAnEndPhraseAtTheConfirmationCancelsAndEnds() async {
        let r = rig(["email alex", "that's all", "is atlas up"], answer: .reply("Drafted it."))
        let mail = FakeMailConfirmer()
        mail.next = item
        r.session.mail = mail
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(mail.approved, [])
        XCTAssertEqual(mail.cancelled, ["p_1"])
        XCTAssertEqual(r.asker.asked, ["email alex"])
        XCTAssertEqual(r.speaker.spoken, [item.readBack])
        XCTAssertEqual(r.cues.played.last, "ending")
    }

    // MARK: - settings are per session

    /// Read once, at the start: a change mid-conversation applies to the next.
    func testSettingsAreReadOncePerSession() async {
        let r = rig(["is atlas up", "and hermes", "that's all"])
        var reads = 0
        r.session.settings = {
            reads += 1
            return VoiceSettings(continuous: true, endPhrases: VoiceSettings.defaultEndPhrases)
        }
        r.session.trigger(r.asker)
        await until(r.finished)
        XCTAssertEqual(reads, 1)
    }
}

final class VoicePhaseActivityTests: XCTestCase {
    /// ActivityKit caps a Live Activity's payload at 4 KB; a long answer must
    /// not take the lock screen down with it.
    func testTheActivityDetailIsCapped() {
        let long = String(repeating: "word ", count: 400)
        XCTAssertLessThanOrEqual(VoicePhase.speaking(long).content.detail.count, VoicePhase.activityDetailLimit + 1)
        let heard = VoicePhase.listening(heard: long + "the end").content.detail
        XCTAssertTrue(heard.hasSuffix("the end"), "the newest words while listening")
        XCTAssertLessThanOrEqual(heard.count, VoicePhase.activityDetailLimit + 1)
        XCTAssertEqual(VoicePhase.speaking("All up.").content.detail, "All up.")
    }
}
