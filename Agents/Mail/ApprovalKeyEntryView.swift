import SwiftUI

/// Paste the base64 key mailgate's install.sh printed once on atlas.
struct ApprovalKeyEntryView: View {
    var onClose: () -> Void
    @State private var text = ""
    @State private var status = ApprovalKey.isSet ? "A key is set. Pasting a new one replaces it." : "No key yet: nothing can be sent."

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sp3) {
            Text("Mail approval key").font(Deck.title).foregroundStyle(Deck.ink)
            Text("Printed once by mailgate's install.sh on atlas. It stays on this phone and proves a send was you.")
                .font(Deck.body).foregroundStyle(Deck.muted)
            SecureField("Approval key (base64)", text: $text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(Theme.sp2).deckCard()
            Text(status).font(Deck.small).foregroundStyle(Deck.muted)
            HStack {
                Button("Close") { onClose() }.buttonStyle(DeckButtonStyle(.ghost))
                Spacer()
                Button("Save") {
                    if ApprovalKey.save(text) {
                        text = ""
                        onClose()
                    } else {
                        status = "That isn't a 32-byte base64 key."
                    }
                }
                .buttonStyle(DeckButtonStyle(.primary))
            }
            Spacer()
        }
        .padding(Theme.sp4)
        .background(Deck.ground)
    }
}
