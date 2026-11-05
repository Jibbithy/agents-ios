import XCTest

@testable import Agents

/// Upload and fetch against a stubbed hub: the request shape is the contract
/// with rack-control's /api/files/upload (raw body, path+name in the query).
final class PhotoHubTests: XCTestCase {
    private func client() -> HubClient {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubFiles.self]
        return HubClient(session: URLSession(configuration: c), token: { .token("t") }, onRejected: { _ in })
    }

    override func setUp() { StubFiles.reset() }

    func testUploadPostsRawBodyWithPathAndName() async throws {
        StubFiles.status = 201
        StubFiles.reply = Data(#"{"path":"/data/photos/inbox/a.jpg","name":"a.jpg","size":3}"#.utf8)
        let saved = try await client().upload(dir: "/data/photos/inbox", name: "a.jpg", data: Data([1, 2, 3]))
        XCTAssertEqual(saved, "/data/photos/inbox/a.jpg")
        let r = try XCTUnwrap(StubFiles.last)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/api/files/upload")
        XCTAssertEqual(r.query["path"], "/data/photos/inbox")
        XCTAssertEqual(r.query["name"], "a.jpg")
        XCTAssertEqual(r.token, "t")
        XCTAssertEqual(r.body, Data([1, 2, 3]))
    }

    func testUpload409IsHttp409() async {
        StubFiles.status = 409
        do {
            _ = try await client().upload(dir: "/d", name: "a.jpg", data: Data([1]))
            XCTFail("409 must throw")
        } catch HubError.http(let code, _) {
            XCTAssertEqual(code, 409)
        } catch { XCTFail("wrong error \(error)") }
    }

    func testFileDataGetsContentByPath() async throws {
        StubFiles.status = 200
        StubFiles.reply = Data([9, 9])
        let d = try await client().fileData(path: "/data/photos/inbox/a.jpg")
        XCTAssertEqual(d, Data([9, 9]))
        XCTAssertEqual(StubFiles.last?.path, "/api/files/content")
        XCTAssertEqual(StubFiles.last?.query["path"], "/data/photos/inbox/a.jpg")
    }
}

final class StubFiles: URLProtocol {
    struct Seen {
        var method: String
        var path: String
        var query: [String: String]
        var token: String?
        var body: Data
    }
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var reply = Data()
    nonisolated(unsafe) static var last: Seen?
    static func reset() {
        status = 200
        reply = Data()
        last = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        var q: [String: String] = [:]
        for i in comps.queryItems ?? [] { q[i.name] = i.value }
        Self.last = Seen(
            method: request.httpMethod ?? "GET", path: comps.path, query: q,
            token: request.value(forHTTPHeaderField: "x-rack-token"), body: Self.body(of: request))
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.reply)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    /// A URLProtocol sees a POST's body as a stream, never as `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            guard n > 0 else { break }
            data.append(buf, count: n)
        }
        return data
    }
}
