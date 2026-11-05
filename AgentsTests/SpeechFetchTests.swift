// AgentsTests/SpeechFetchTests.swift
import XCTest

@testable import Agents

/// `HubClient.speech`: POST /api/tts, and the audio streamed back.
///
/// EVERY WAY IT CAN FAIL IS ITS OWN ERROR, because `FallbackVoice` reads the
/// rest in the Apple voice on any of them and the log has to say which. And
/// the token rules are the rest of the app's: a 401 is the way back to the
/// token screen, and a locked Keychain never is.
@MainActor
final class SpeechFetchTests: XCTestCase {

    /// What `onRejected` was handed: the token each 401 carried.
    @MainActor final class Rejections {
        private(set) var sent: [String?] = []
        func record(_ token: String?) { sent.append(token) }
    }

    override func setUp() {
        super.setUp()
        StubTTS.reset()
    }

    private func hub(_ read: TokenStore.Read = .token("tok"), rejections: Rejections = Rejections()) -> HubClient {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubTTS.self]
        return HubClient(
            session: URLSession(configuration: c),
            token: { read },
            onRejected: { await rejections.record($0) })
    }

    /// Everything the stream yielded, and what it ended with.
    private func drain(_ stream: AsyncThrowingStream<Data, Error>) async -> (Data, Error?) {
        var all = Data()
        do {
            for try await piece in stream { all.append(piece) }
            return (all, nil)
        } catch {
            return (all, error)
        }
    }

    private func bytes(_ count: Int, from start: Int = 0) -> Data {
        Data((0..<count).map { UInt8((start + $0) % 251) })
    }

    // MARK: - the request, and the audio

    func testAsksForTheTextWithTheToken() async throws {
        StubTTS.chunks = [bytes(10)]
        _ = await drain(hub().speech("Atlas is up."))

        let request = try XCTUnwrap(StubTTS.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/tts")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-rack-token"), "tok")
        XCTAssertNil(request.value(forHTTPHeaderField: "authorization"), "the hub's header is x-rack-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        let body = try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(StubTTS.bodies.first))
        XCTAssertEqual(body, ["text": "Atlas is up."])
    }

    func testAVoiceIsAskedForByName() async throws {
        StubTTS.chunks = [bytes(10)]
        _ = await drain(hub().speech("Hi.", voice: "bf_emma"))
        let body = try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(StubTTS.bodies.first))
        XCTAssertEqual(body, ["text": "Hi.", "voice": "bf_emma"])
    }

    /// Every byte, in order, however the network cuts it: odd-sized pieces
    /// included, since a sample can straddle two.
    func testStreamsEveryByteThrough() async {
        let sent = [bytes(5_001), bytes(7, from: 3), bytes(9_999, from: 11)]
        StubTTS.chunks = sent
        let (got, error) = await drain(hub().speech("Atlas is up."))
        XCTAssertNil(error)
        XCTAssertEqual(got, sent.reduce(Data(), +))
    }

    // MARK: - the token

    /// A rotated token: the hub is told which token it refused, as every
    /// other call does, so HubToken can clear it and show the token screen.
    func testA401RejectsTheTokenItCarried() async {
        StubTTS.status = 401
        let rejections = Rejections()
        let (_, error) = await drain(hub(rejections: rejections).speech("Hi."))
        XCTAssertEqual(error as? TTSError, .unauthorized)
        XCTAssertEqual(rejections.sent, ["tok"])
    }

    func testNoTokenGoesToTheTokenScreenWithoutAsking() async {
        let rejections = Rejections()
        let (_, error) = await drain(hub(.missing, rejections: rejections).speech("Hi."))
        XCTAssertEqual(error as? TTSError, .unauthorized)
        XCTAssertEqual(rejections.sent, [nil])
        XCTAssertTrue(StubTTS.requests.isEmpty)
    }

    /// THE LOCK-SCREEN RULE (ec939fa): a Keychain that will not decrypt yet
    /// fails this reading, and says nothing about the token.
    func testALockedKeychainFailsWithoutTouchingTheToken() async {
        let rejections = Rejections()
        let (_, error) = await drain(hub(.locked, rejections: rejections).speech("Hi."))
        XCTAssertEqual(error as? TTSError, .locked)
        XCTAssertTrue(rejections.sent.isEmpty, "a locked read went to HubToken.rejected")
        XCTAssertTrue(StubTTS.requests.isEmpty)
    }

    // MARK: - the hub saying no

    func testBusyUnavailableAndRefusedAreEachTheirOwn() async {
        for (status, expected) in [(429, TTSError.busy), (502, .unavailable), (413, .refused(413)), (400, .refused(400))] {
            StubTTS.reset()
            StubTTS.status = status
            let rejections = Rejections()
            let (got, error) = await drain(hub(rejections: rejections).speech("Hi."))
            XCTAssertEqual(error as? TTSError, expected, "\(status)")
            XCTAssertTrue(got.isEmpty)
            XCTAssertTrue(rejections.sent.isEmpty, "only a 401 is about the token")
        }
    }

    func testNothingAnsweringIsUnreachable() async {
        StubTTS.failure = URLError(.cannotConnectToHost)
        let (_, error) = await drain(hub().speech("Hi."))
        XCTAssertEqual(error as? TTSError, .unreachable)
    }

    /// Kokoro dying mid-reading tears the connection rather than ending it.
    /// What did arrive is handed on, and then it is an error, never a clean
    /// end that would pass for the whole of it.
    func testATornStreamIsNotAnEnd() async {
        StubTTS.chunks = [bytes(6_001)]
        StubTTS.ending = .tear
        let (got, error) = await drain(hub().speech("Atlas is up."))
        XCTAssertEqual(got, bytes(6_001))
        XCTAssertEqual(error as? TTSError, .torn)
    }

    // MARK: - cancelling

    /// `KokoroVoice.stop` ends its reading of the stream, and that has to
    /// end the request too, or atlas goes on synthesising for nobody and
    /// holds one of its four places.
    func testLettingGoOfTheStreamCancelsTheRequest() async {
        StubTTS.chunks = [bytes(100)]
        StubTTS.ending = .hold
        let started = expectation(description: "the request reached the hub")
        let stopped = expectation(description: "the request was cancelled")
        StubTTS.started = started
        StubTTS.stopped = stopped

        let client = hub()
        let reader = Task { await drain(client.speech("Atlas is up.")) }
        await fulfillment(of: [started], timeout: 5)
        reader.cancel()
        await fulfillment(of: [stopped], timeout: 5)
        _ = await reader.value
    }
}

/// Plays the hub's /api/tts: `status`, then `chunks`, then `ending`. Or,
/// with `failure`, no answer at all.
final class StubTTS: URLProtocol {
    enum Ending { case finish, tear, hold }

    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var chunks: [Data] = []
    nonisolated(unsafe) static var ending = Ending.finish
    nonisolated(unsafe) static var failure: URLError?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var started: XCTestExpectation?
    nonisolated(unsafe) static var stopped: XCTestExpectation?

    static func reset() {
        status = 200
        chunks = []
        ending = .finish
        failure = nil
        requests = []
        bodies = []
        started = nil
        stopped = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        Self.bodies.append(Self.body(of: request))
        Self.started?.fulfill()
        Self.started = nil
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let type = Self.status == 200 ? "audio/L16; rate=24000; channels=1" : "application/json"
        let resp = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
            headerFields: ["content-type": type])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if Self.status != 200 {
            client?.urlProtocol(self, didLoad: Data(#"{"error":"stub"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        for chunk in Self.chunks { client?.urlProtocol(self, didLoad: chunk) }
        switch Self.ending {
        case .finish: client?.urlProtocolDidFinishLoading(self)
        case .tear:
            // LATE, as Kokoro dies: after the audio before it has been read.
            // Torn at once, URLSession drops what it had not handed over yet.
            nonisolated(unsafe) let me = self
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                me.client?.urlProtocol(me, didFailWithError: URLError(.networkConnectionLost))
            }
        case .hold: break
        }
    }

    override func stopLoading() {
        Self.stopped?.fulfill()
        Self.stopped = nil
    }

    /// A URLProtocol sees a POST's body as a stream, never as `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
