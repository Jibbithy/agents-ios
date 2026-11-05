import Foundation

/// The photos waiting in the composer, and their uploads.
///
/// ALL-OR-NOTHING: `uploadAll` returns paths only when every photo is on
/// atlas; otherwise nil and the message is not sent. An uploaded photo keeps
/// its saved path, so a retry uploads only the ones that failed.
@Observable
@MainActor
final class PhotoTray {
    static let limit = 10

    enum State: Equatable {
        case waiting, uploading
        case uploaded(String)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let jpeg: Data
        var state: State = .waiting
    }

    private(set) var items: [Item] = []

    var isEmpty: Bool { items.isEmpty }
    var room: Int { Self.limit - items.count }

    func add(_ jpeg: Data) {
        guard items.count < Self.limit else { return }
        items.append(Item(jpeg: jpeg))
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    func clear() { items.removeAll() }

    /// Sequential, in order. `upload` gets a file NAME and the bytes, returns
    /// the saved path. A 409 retries once with a "b" suffix.
    func uploadAll(
        at date: Date = Date(), timeZone: TimeZone = .current,
        upload: @MainActor (String, Data) async throws -> String
    ) async -> [String]? {
        for i in items.indices {
            if case .uploaded = items[i].state { continue }
            items[i].state = .uploading
            let name = PhotoMessage.fileName(at: date, index: i + 1, timeZone: timeZone)
            do {
                let path: String
                do { path = try await upload(name, items[i].jpeg) } catch HubError.http(409, _) {
                    path = try await upload(PhotoMessage.fileName(at: date, index: i + 1, suffix: "b", timeZone: timeZone), items[i].jpeg)
                }
                items[i].state = .uploaded(path)
            } catch {
                items[i].state = .failed(Self.describe(error))
            }
        }
        let paths = items.compactMap { if case .uploaded(let p) = $0.state { p } else { nil } }
        return paths.count == items.count ? paths : nil
    }

    private static func describe(_ e: Error) -> String {
        switch e {
        case HubError.http(404, _): "Photo inbox missing on atlas"
        case HubError.http(413, _): "Photo too large"
        case HubError.unreachable: "Can't reach atlas"
        default: "Upload failed"
        }
    }
}
