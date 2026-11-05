// Agents/Voice/VoiceBar.swift
import SwiftUI

/// What a voice session is doing, over the composer, while the app is open -
/// the Live Activity's job everywhere else, and the Dynamic Island does not
/// show the app's own activity while the app is on screen.
///
/// OVER THE COMPOSER, NOT BESIDE IT: typing while a spoken question is in
/// flight would start a second turn in the same chat.
struct VoiceBar: View {
    let phase: VoicePhase
    /// Send while listening, cut in while an answer is read - see
    /// `VoiceSession.press`. The bar covers the composer's Talk, so without
    /// this both would be unreachable in the app.
    let press: () -> Void
    let cancel: () -> Void

    var body: some View {
        // sp2, not the composer's sp3: at 390pt the 12pt this saves is what
        // lets a short answer like "All three nodes are up." fit on one line.
        HStack(spacing: Theme.sp2) {
            Image(systemName: phase.symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Deck.accentInk)
                .symbolEffect(.variableColor.iterative, isActive: phase.isListening)
                // One width for every phase's symbol, so the text beside it
                // does not shift sideways at each change.
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(phase.label).deckLabel()
                Text(phase.detail)
                    .font(Deck.body)
                    .foregroundStyle(Deck.ink)
                    // Two lines' room always, so the bar does not grow the
                    // moment the words heard wrap.
                    .lineLimit(2, reservesSpace: true)
                    // The newest words are the ones worth seeing while you
                    // speak; an answer reads from its start.
                    .truncationMode(phase.isListening ? .head : .tail)
            }
            // The text as one element, the buttons as buttons of their own.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            pressButton
            // AN ICON, NOT A SECOND TEXT BUTTON: two orange-red words side by
            // side read alike, and between them left the words heard about
            // 120pt. The top bar's own icon button, so it matches the pencil.
            Button(action: cancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(DeckIconButtonStyle())
            .accessibilityLabel("Cancel voice")
        }
        .padding(.horizontal, Theme.sp4)
        .padding(.vertical, Theme.sp3)
        .frame(maxWidth: .infinity)
        .deckBar(.bottom)
    }

    /// Send while listening, Talk while an answer is read, and faded out
    /// otherwise. NOT ON A FAILURE: `.failed` does not say which kind, and
    /// after "Mic busy." or a failed listen a press only stops the speech and
    /// ends, so Talk would promise a listen that never comes. Cancel is there.
    ///
    /// BOTH LABELS ARE ALWAYS LAID OUT, one of them invisible, and the button
    /// is faded rather than removed when it has no job. The slot is therefore
    /// always the wider label's width, so neither the swap nor the fade moves
    /// Cancel or the text beside it. NOT `.disabled` for the fade: a disabled
    /// Deck button gives up its shadow's 3pt, which would shift Cancel.
    private var pressButton: some View {
        let sends = phase.isListening
        let shown = sends || isSpeaking
        return Button(action: press) {
            ZStack {
                Label("Send", systemImage: "arrow.up").opacity(sends ? 1 : 0)
                Label("Talk", systemImage: "mic.fill").opacity(sends ? 0 : 1)
            }
        }
        .buttonStyle(.deckPrimary)
        .accessibilityLabel(sends ? "Send what you said" : "Talk again")
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
    }

    private var isSpeaking: Bool {
        if case .speaking = phase { true } else { false }
    }
}
