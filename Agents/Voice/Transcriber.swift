// Agents/Voice/Transcriber.swift
import AVFoundation
import os
import Speech
import UIKit

/// Where the one mic tap's buffers go: into a recognition request while
/// someone is being listened to, and nowhere otherwise.
///
/// A LOCK, NOT AN ACTOR: `append` runs on the real-time audio thread, which
/// must never wait on the main actor. `route` swaps the destination from the
/// main actor. The append happens INSIDE the lock, so once `route(to: nil)`
/// returns nothing more reaches the old request - which is what lets its
/// audio be ended straight after. An append is a copy into the request's
/// queue, so the main actor never waits long on it.
final class MicFeed: @unchecked Sendable {
    static let shared = MicFeed()
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func route(to request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock { self.request = request }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }
}

/// Apple's speech recogniser on the phone's mic, or the AirPods'.
///
/// IT DOES NOT OWN THE MIC. `AudioSessionVoice` runs the one input tap for the
/// whole session - see there for why the mic has to stay open while Atlas
/// thinks - and this only routes those buffers into a recognition request
/// while it is listening.
///
/// ON-DEVICE WHEREVER THE PHONE SUPPORTS IT: what you say to Atlas is not sent
/// to Apple, and it works with no signal. It ends itself - see `Endpointer` -
/// so a question needs no second press.
@MainActor
final class Transcriber: Listening {
    /// How long the recogniser gets, once the question is over - the
    /// endpointer called it, or a press sent it - to deliver its final result.
    ///
    /// THE FINAL RESULT IS OFTEN BETTER THAN THE LAST PARTIAL: it is where the
    /// recogniser settles the last word, which the partials had only guessed.
    /// Stopping the moment the question ends would throw that away. So the
    /// audio is ended instead, the final result - usually a few hundred ms
    /// later - completes the listen itself, and this is only the backstop for
    /// one that never comes. Either way the listen returns the best text by
    /// then.
    static let graceForFinal: Duration = .milliseconds(500)

    /// Kept, not made per listen: the recognition task is the recogniser's,
    /// and it is not worth finding out whether one outlives its recogniser.
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var clock: Task<Void, Never>?
    private var endpointer = Endpointer(started: .now)
    private var heard = ""
    private var waiting: CheckedContinuation<String?, Error>?
    /// Which listen is the current one, so that a late callback from an
    /// earlier listen's recognition cannot end this one.
    private var listens = 0
    /// A `finish` or `cancel` that landed before there was a continuation to
    /// resume, while `listen` was still waiting on the speech permission (on
    /// the first run, a system prompt). Honoured as soon as the continuation
    /// exists; either way nothing has been heard yet, so both return nil.
    /// Cleared at the start of every listen, so one that lands BETWEEN
    /// listens does nothing.
    private var endedEarly = false

    func listen(patient: Bool, onWords: @escaping @MainActor @Sendable (String) -> Void) async throws -> String? {
        // ONE LISTEN AT A TIME. The session never overlaps two; a second
        // would overwrite the first one's continuation and leave it hanging.
        assert(waiting == nil, "Transcriber.listen called while a listen is in progress")
        endedEarly = false
        heard = ""
        listens += 1
        let id = listens
        guard await Self.permitted() else { throw VoiceError.notAllowed }
        guard let recognizer, recognizer.isAvailable else {
            Logger.voice.error("Voice: the recogniser is \(self.recognizer == nil ? "missing" : "not available", privacy: .public)")
            throw VoiceError.speechUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            guard !endedEarly else { complete(); return }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            self.request = request
            endpointer = Endpointer(started: .now, patient: patient)

            recognition = recognizer.recognitionTask(with: request, resultHandler: Self.results { [weak self] text, done, error in
                // Late callbacks - the error that cancelling a recognition
                // fires, or anything after this listen is over - are dropped.
                guard let self, self.listens == id, self.waiting != nil else { return }
                if let text = Self.revision(of: self.heard, to: text) {
                    self.heard = text
                    // ANY change counts, a punctuation fix included: a revision
                    // means the recogniser is still working on what was said.
                    self.endpointer.heard(at: .now)
                    onWords(text)
                } else if done, text?.isEmpty == true, !self.heard.isEmpty {
                    Logger.voice.notice("Voice: the recogniser's final result was empty; keeping the \(BargeIn.words(self.heard).count, privacy: .public)-word transcript")
                }
                guard done else { return }
                let failed = error.map { !Self.heardNoSpeech($0) } ?? false
                if let error {
                    Logger.voice.notice("Voice: the recogniser ended with \(error.domainAndCode, privacy: .public)\(failed ? "" : " (no speech)", privacy: .public)")
                }
                // A RECOGNISER THAT FAILED BEFORE HEARING ANYTHING IS AN ERROR,
                // not silence: returned as nil, an on-device failure on a
                // locked phone would end the session without a word.
                if failed && self.heard.isEmpty {
                    self.complete(throwing: .speechUnavailable)
                } else {
                    self.complete()
                }
            })
            MicFeed.shared.route(to: request)
            clock = Task { [weak self] in
                // Until the endpointer calls the question over...
                var ending: Endpointer.Ending?
                repeat {
                    try? await Task.sleep(for: .milliseconds(250))
                    // CANCELLED MEANS THIS LISTEN IS OVER, or is settling.
                    // `complete` and `settle` cancel the clock on the main
                    // actor, where this also runs, so a clock outlived by its
                    // listen never acts on the next one.
                    guard !Task.isCancelled, let self else { return }
                    ending = self.endpointer.ending(at: .now)
                } while ending == nil
                // ...then, if anything was said, a moment for the final
                // result. Nothing said, nothing to wait for.
                if ending == .spoke { self?.settle() } else { self?.complete() }
            }
        }
    }

    /// Stop listening and return what was heard, after the same moment for
    /// the final result that an endpointed question gets - see `settle`.
    /// With no listen going, nothing.
    func finish() {
        guard waiting != nil else { endedEarly = true; return }
        settle()
    }

    /// Stop now and return nil. With no listen going, nothing.
    func cancel() {
        guard waiting != nil else { endedEarly = true; return }
        heard = ""
        complete()
    }

    /// Ends the audio and gives the recogniser `graceForFinal` to deliver its
    /// final result, which completes the listen; the clock completes it if
    /// none comes. Once only: a second call finds the audio already ended.
    private func settle() {
        guard request != nil else { return }
        endAudio()
        clock?.cancel()
        clock = Task { [weak self] in
            try? await Task.sleep(for: Transcriber.graceForFinal)
            guard !Task.isCancelled else { return }
            self?.complete()
        }
    }

    /// Ends the audio but not the recognition, so it can still deliver its
    /// final result. The mic is unrouted first: nothing may be appended to a
    /// request after its end, and `MicFeed.route` guarantees nothing is.
    private func endAudio() {
        MicFeed.shared.route(to: nil)
        request?.endAudio(); request = nil
    }

    /// Stops listening and hands back what was heard, or `error`. EVERY WAY A
    /// LISTEN ENDS COMES THROUGH HERE - finish, cancel, the clock, the
    /// recogniser's final result or error - and the `guard` is what makes the
    /// continuation resume exactly once whichever of them lands first.
    /// Cancelling the recognition task fires its handler once more with an
    /// error, which is dropped there.
    private func complete(throwing error: VoiceError? = nil) {
        guard let waiting else { return }
        self.waiting = nil
        clock?.cancel(); clock = nil
        endAudio()
        recognition?.cancel(); recognition = nil
        if let error {
            waiting.resume(throwing: error)
        } else {
            waiting.resume(returning: heard.isEmpty ? nil : heard)
        }
    }

    /// The recogniser's callback, hopped onto the main actor: the text so
    /// far, whether the recognition is over, and the error it ended with, if
    /// any - which may only be that it heard no speech. NONISOLATED ON
    /// PURPOSE: a closure written inside this @MainActor class would be
    /// inferred main-actor-isolated, and if the recogniser ever calls it from
    /// another queue, Swift 6 traps at run time rather than hopping.
    nonisolated private static func results(
        _ handle: @escaping @MainActor @Sendable (String?, Bool, (any Error)?) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in handle(text, done, error) }
        }
    }

    /// What the transcript becomes on a result from the recogniser: `text`
    /// when it says something new, nil when there is nothing to change.
    ///
    /// AN EMPTY RESULT NEVER REPLACES WORDS. The on-device recogniser's FINAL
    /// result for a short utterance - "Dismissed", "Send" - can come back with
    /// no transcription at all, after partials that had the word (the phone,
    /// 2026-09-23: "Dismissed" heard and then dropped, five listens in a row).
    /// Taken as a revision it emptied the transcript at the last moment, the
    /// listen returned nothing, and the conversation silently listened again.
    /// The partial is what was said; the empty final is noise.
    nonisolated static func revision(of heard: String, to text: String?) -> String? {
        guard let text, !text.isEmpty, text != heard else { return nil }
        return text
    }

    /// kAFAssistantErrorDomain 1110, "Failed to recognize any speech" (see
    /// SFSpeechRecognitionTask.h): someone who said nothing, not a failure.
    nonisolated private static func heardNoSpeech(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "kAFAssistantErrorDomain" && error.code == 1110
    }

    /// Speech permission. The mic's is `AudioSessionVoice.begin`'s. THE SYSTEM
    /// PROMPT ONLY APPEARS WHILE THE APP IS ON SCREEN, so from the lock screen
    /// (a launch there is `.background`) an undecided permission counts as no,
    /// and the session says to open the app and tap the mic once. NOT
    /// `== .active`: straight after the mic prompt the app is still
    /// `.inactive` from that alert, and the first-ever tap would be refused.
    private static func permitted() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            guard UIApplication.shared.applicationState != .background else {
                Logger.voice.notice("Voice: speech recognition is not allowed yet, and the app is in the background")
                return false
            }
            let allowed = await speechAuthorization() == .authorized
            if !allowed { Logger.voice.notice("Voice: speech recognition was refused at the prompt") }
            return allowed
        default:
            Logger.voice.notice("Voice: speech recognition is turned off for Agents in Settings")
            return false
        }
    }

    nonisolated private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
    }
}
