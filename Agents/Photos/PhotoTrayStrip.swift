import SwiftUI

/// Thumbnails of the photos waiting in the composer. A failed upload shows a
/// red badge with the reason; Send retries only those.
struct PhotoTrayStrip: View {
    let tray: PhotoTray
    /// True while uploading: removing a photo mid-upload would shift the
    /// indices `uploadAll` is walking.
    let locked: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.sp2) {
                ForEach(tray.items) { item in
                    ZStack(alignment: .topTrailing) {
                        thumb(item.jpeg)
                            .overlay { overlay(item.state) }
                        if !locked {
                            Button {
                                tray.remove(item.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 18))
                                    .foregroundStyle(Deck.ink, Deck.surface)
                            }
                            .accessibilityLabel("Remove photo")
                            .offset(x: 6, y: -6)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.sp4)
            .padding(.top, Theme.sp2)
        }
    }

    // Full-size decode into a 56 pt tile: fine for the 10-photo cap. If
    // scrolling stutters, downsample with `preparingThumbnail(of:)`.
    private func thumb(_ data: Data) -> some View {
        Group {
            if let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Color.gray
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private func overlay(_ s: PhotoTray.State) -> some View {
        switch s {
        case .uploading: ProgressView()
        case .failed(let why):
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                .accessibilityLabel(why)
        default: EmptyView()
        }
    }
}
