import SwiftUI

/// One photo stored on atlas, fetched through the hub with the app's token
/// (AsyncImage cannot set headers). A failed fetch shows a grey tile with the
/// file name; tap opens full screen.
struct HubPhoto: View {
    let path: String
    @State private var image: UIImage?
    @State private var failed = false
    @State private var full = false

    var body: some View {
        Button {
            if image != nil { full = true }
        } label: {
            ZStack {
                Deck.surface
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed {
                    Text((path as NSString).lastPathComponent)
                        .font(.caption2).foregroundStyle(Deck.muted).padding(4)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo \((path as NSString).lastPathComponent)")
        .task(id: path) {
            do {
                let data = try await HubClient.shared.fileData(path: path)
                image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 300, height: 300))
                failed = image == nil
            } catch { failed = true }
        }
        .fullScreenCover(isPresented: $full) { FullPhoto(path: path) }
    }
}

private struct FullPhoto: View {
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundStyle(.white)
            }
            .padding()
            .accessibilityLabel("Close")
        }
        .task { image = (try? await HubClient.shared.fileData(path: path)).flatMap(UIImage.init(data:)) }
    }
}
