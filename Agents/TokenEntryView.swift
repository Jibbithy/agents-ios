import SwiftUI

/// The one screen that writes a credential.
///
/// Two ways here: RootView shows it whenever there is no usable token (first
/// run, or the hub just answered 401 - see HubToken), and "Change token" at the
/// foot of the chats drawer opens it as a sheet over a working app.
struct TokenEntryView: View {
    /// Set only for the sheet. Shows Cancel, and closes the sheet after a
    /// save. The old token keeps working until a new one has been PROVED, so
    /// backing out of a change costs nothing.
    var onClose: (() -> Void)? = nil

    @State private var typed = ""
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        // NO NavigationStack: nothing pushes from here, and the stack was only
        // ever there to draw the title. A Deck bar draws it now.
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sp4 + Theme.sp2) {
                DeckFormSection(title: "Hub token") {
                    VStack(alignment: .leading, spacing: Theme.sp2) {
                        // A 64-character token autocapitalised or autocorrected
                        // is a silent 401 that looks like the hub is broken.
                        // MONO so 0/O and l/1 can be told apart when checking
                        // it against the terminal.
                        // The prompt in `muted`: the system placeholder grey
                        // is under 3:1 on Deck's surface.
                        TextField(
                            "x-rack-token", text: $typed,
                            prompt: Text("x-rack-token").foregroundStyle(Deck.muted),
                            axis: .vertical
                        )
                        .textFieldStyle(DeckFieldStyle(invalid: problem != nil, mono: true))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(2...4)
                        Text("On atlas: cat /var/lib/rack-hub/token")
                            .font(Deck.mono(12, .regular, relativeTo: .footnote))
                            .foregroundStyle(Deck.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Theme.sp3)
                }

                if let problem {
                    DeckErrorText(problem)
                }

                Button(checking ? "Checking…" : "Save") { Task { await check() } }
                    .buttonStyle(.deckPrimary)
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
            }
            .padding(Theme.sp4)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("Agents")
                    .font(Deck.title)
                    .textCase(.uppercase)
                    .foregroundStyle(Deck.ink)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let onClose {
                    Button("Cancel") { onClose() }
                        .buttonStyle(.deckGhost)
                }
            }
            .padding(.horizontal, Theme.sp4)
            .padding(.vertical, Theme.sp4)
            .deckBar(.top)
        }
        .deckGround()
    }

    /// PROVE THE TOKEN BEFORE STORING IT. A typo committed to the Keychain
    /// would 401 on the first call and bounce straight back here - and, over
    /// "Change token", would have thrown away a token that worked.
    private func check() async {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        checking = true
        problem = nil
        defer { checking = false }
        if await HubClient.shared.validate(t) {
            // Keychain AND RootView's switch, in one step - see HubToken.
            HubToken.shared.saved(t)
            onClose?()
        } else {
            problem = "That token was rejected, or the rack is unreachable. Is Tailscale on?"
        }
    }
}
