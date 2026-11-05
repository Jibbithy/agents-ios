// Agents/Voice/VoiceSettingsView.swift
import SwiftUI

/// Hands-free conversation on or off, and the phrases that end one. From the
/// drawer's footer: this app has no settings screen.
///
/// SAVED ON SAVE, NOT AS YOU TYPE, and read at the start of the NEXT session
/// (see `VoiceSettings`): an edit made mid-conversation cannot change the
/// rules of the one running.
struct VoiceSettingsView: View {
    var onClose: () -> Void
    @State private var continuous: Bool
    @State private var phrases: String

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let s = VoiceSettings.load()
        _continuous = State(initialValue: s.continuous)
        _phrases = State(initialValue: s.endPhrases.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sp3) {
            Text("Voice chat").font(Deck.title).foregroundStyle(Deck.ink)
            Toggle(isOn: $continuous) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep listening after answers").font(Deck.body).foregroundStyle(Deck.ink)
                    Text("Talk back and forth hands-free. Ends when you say an end phrase, or after about 25 seconds of quiet.")
                        .font(Deck.small).foregroundStyle(Deck.muted)
                }
            }
            .tint(Deck.accentInk)
            Text("End phrases, one per line").deckLabel()
            TextEditor(text: $phrases)
                .font(Deck.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110)
                .padding(Theme.sp2)
                .deckCard()
            Text("Said on its own or at the end (\u{201C}ok, that\u{2019}s all\u{201D}), never as a question. Mail \u{201C}send\u{201D} still works mid-chat.")
                .font(Deck.small).foregroundStyle(Deck.muted)
            HStack {
                Button("Close") { onClose() }.buttonStyle(DeckButtonStyle(.ghost))
                Button("Defaults") {
                    continuous = true
                    phrases = VoiceSettings.defaultEndPhrases.joined(separator: "\n")
                }
                .buttonStyle(DeckButtonStyle(.ghost))
                Spacer()
                Button("Save") {
                    VoiceSettings(continuous: continuous, endPhrases: VoiceSettings.phrases(from: phrases)).save()
                    onClose()
                }
                .buttonStyle(DeckButtonStyle(.primary))
            }
            Spacer()
        }
        .padding(Theme.sp4)
        .background(Deck.ground)
    }
}

/// The words being heard, as a faint bubble of yours at the foot of the
/// thread, while a voice session listens for a question to THIS chat. The
/// moment it is asked, the real bubble takes its place - `ChatModel.start`
/// appends it in the same main-actor turn the phase leaves `.listening`, so
/// there is no frame with both or neither.
///
/// A VIEW OF ITS OWN SO THAT ONLY IT READS `phase`, for the reason on
/// `VoiceOverlay`: the chat around it must not re-render on every partial.
struct LiveHeardRow: View {
    static let scrollID = "heard"
    let model: ChatModel
    let proxy: ScrollViewProxy
    private let voice = VoiceSession.shared

    var body: some View {
        let heard = shown
        Group {
            if let heard {
                HStack {
                    Spacer(minLength: 40)
                    Text(heard)
                        .font(Theme.message)
                        .foregroundStyle(Deck.inkInverse)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Theme.sp3)
                        .deckTile(fill: Deck.ink)
                        .opacity(0.55)
                }
                .accessibilityLabel("Hearing: \(heard)")
                .id(Self.scrollID)
            }
        }
        .onChange(of: heard) {
            if heard != nil { proxy.scrollTo(Self.scrollID, anchor: .bottom) }
        }
    }

    private var shown: String? {
        guard case .listening(let heard) = voice.phase, !heard.isEmpty, voice.isAsking(model) else { return nil }
        return heard
    }
}

extension VoiceSession {
    /// This session's questions go into `model`'s chat: the composer mic's
    /// chat, or the voice chat's current model.
    func isAsking(_ model: ChatModel) -> Bool {
        if let turn = asking as? ChatModelTurn { return turn.model === model }
        if let atlas = asking as? AtlasVoice { return atlas.model === model }
        return false
    }
}
