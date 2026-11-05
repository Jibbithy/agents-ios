import XCTest

@testable import Agents

@MainActor
final class PhotoTrayTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let utc = TimeZone(identifier: "UTC")!

    /// Records every call; fails the names in `failing` once each.
    /// `@MainActor`: Swift 6 doesn't inherit the enclosing test class's
    /// isolation for a nested type, and `PhotoTray.uploadAll`'s closure
    /// parameter is `@MainActor` (it captures `PhotoTray`'s own state) -
    /// without this, passing `up.run` is a non-Sendable-value-crosses-actor
    /// compile error, not a real concurrency risk (everything here is main
    /// actor already).
    @MainActor
    final class FakeUpload {
        var calls: [String] = []
        var failing: Set<String> = []
        var conflict: Set<String> = []
        func run(_ name: String, _ data: Data) async throws -> String {
            calls.append(name)
            if conflict.contains(name) { throw HubError.http(409, "") }
            if failing.remove(name) != nil { throw HubError.unreachable }
            return PhotoMessage.inbox + "/" + name
        }
    }

    func testAllUploadInOrderAndReturnPaths() async {
        let tray = PhotoTray()
        tray.add(Data([1]))
        tray.add(Data([2]))
        let up = FakeUpload()
        let paths = await tray.uploadAll(at: date, timeZone: utc, upload: up.run)
        XCTAssertEqual(up.calls, ["2026-09-21_141320_1.jpg", "2026-09-21_141320_2.jpg"])
        XCTAssertEqual(paths, [PhotoMessage.inbox + "/2026-09-21_141320_1.jpg", PhotoMessage.inbox + "/2026-09-21_141320_2.jpg"])
    }

    func testOneFailureReturnsNilAndMarksIt() async {
        let tray = PhotoTray()
        tray.add(Data([1]))
        tray.add(Data([2]))
        let up = FakeUpload()
        up.failing = ["2026-09-21_141320_2.jpg"]
        let paths = await tray.uploadAll(at: date, timeZone: utc, upload: up.run)
        XCTAssertNil(paths)
        guard case .uploaded = tray.items[0].state else { return XCTFail("first should be uploaded") }
        guard case .failed = tray.items[1].state else { return XCTFail("second should be failed") }
    }

    /// Retry must not re-upload what already made it.
    func testRetrySkipsUploaded() async {
        let tray = PhotoTray()
        tray.add(Data([1]))
        tray.add(Data([2]))
        let up = FakeUpload()
        up.failing = ["2026-09-21_141320_2.jpg"]
        _ = await tray.uploadAll(at: date, timeZone: utc, upload: up.run)
        let later = date.addingTimeInterval(5)
        let paths = await tray.uploadAll(at: later, timeZone: utc, upload: up.run)
        XCTAssertEqual(up.calls, ["2026-09-21_141320_1.jpg", "2026-09-21_141320_2.jpg", "2026-09-21_141325_2.jpg"])
        XCTAssertEqual(paths?.count, 2)
        XCTAssertEqual(paths?.first, PhotoMessage.inbox + "/2026-09-21_141320_1.jpg")
    }

    func testConflictRetriesOnceWithSuffix() async {
        let tray = PhotoTray()
        tray.add(Data([1]))
        let up = FakeUpload()
        up.conflict = ["2026-09-21_141320_1.jpg"]
        let paths = await tray.uploadAll(at: date, timeZone: utc, upload: up.run)
        XCTAssertEqual(up.calls, ["2026-09-21_141320_1.jpg", "2026-09-21_141320_1b.jpg"])
        XCTAssertEqual(paths, [PhotoMessage.inbox + "/2026-09-21_141320_1b.jpg"])
    }

    func testCapAtTenAndRemove() {
        let tray = PhotoTray()
        for i in 0..<12 { tray.add(Data([UInt8(i)])) }
        XCTAssertEqual(tray.items.count, 10)
        tray.remove(tray.items[0].id)
        XCTAssertEqual(tray.items.count, 9)
        tray.clear()
        XCTAssertTrue(tray.items.isEmpty)
    }
}
