import Foundation
import os

enum HubError: LocalizedError, Sendable {
    /// The hub answered, and said no. The token is wrong or gone.
    case unauthorized
    /// Nothing answered. Almost always Tailscale being off - example.com
    /// resolves for everyone and routes for nobody outside the tailnet.
    case unreachable
    case http(Int, String)
    case decoding(String)
    /// A call this app built wrong, caught before it reached the network. Never
    /// the hub's fault, so it must not borrow one of the cases above - .http(0,)
    /// would blame the hub for a bug on this side of the wire.
    case badRequest(String)
    /// The Keychain would not hand the token over because the phone is locked
    /// (see TokenStore.Read). The token is fine; this request just cannot
    /// carry it. Never .unauthorized, which would send the user to re-paste it.
    case locked

    var errorDescription: String? {
        switch self {
        case .unauthorized: "That token was rejected."
        case .unreachable: "Can't reach the rack. Is Tailscale connected?"
        case .http(let c, let b): "The hub answered \(c): \(b)"
        case .decoding(let d): "Couldn't read the hub's answer: \(d)"
        case .badRequest(let d): "That request was malformed: \(d)"
        case .locked: "The phone is locked. Unlock it, then try again."
        }
    }
}

/// Why /api/tts gave no speech, or stopped partway. `FallbackVoice` reads the
/// rest in the Apple voice on every one of them; they are told apart for the
/// log, and for the 401's trip to the token screen, which has already been
/// taken by the time this is thrown.
enum TTSError: Error, Equatable, Sendable {
    /// 401, or no token stored: `HubToken.rejected` has been told.
    case unauthorized
    /// The Keychain will not decrypt the token yet. Not `.unauthorized`, for
    /// the reason on `HubError.locked`.
    case locked
    /// 429 `{error:"voice busy"}`: four readings already in flight on atlas.
    case busy
    /// 502 `{error:"voice unavailable"}`: Kokoro is down or unreachable.
    case unavailable
    /// Any other answer: 400, 413, a hub without the route.
    case refused(Int)
    /// No answer at all: off the tailnet, or the hub is down.
    case unreachable
    /// THE AUDIO STOPPED PARTWAY. Kokoro dying mid-reading tears the
    /// connection rather than ending it, and this is never mistaken for the
    /// end of the speech.
    case torn
    /// Nothing arrived for seconds with nothing left playing: the phone
    /// walked out of Wi-Fi, or Kokoro wedged. Noticed by `KokoroVoice`, not
    /// by the request, which would take its whole timeout to say so.
    case stalled
}

actor HubClient {
    static let shared = HubClient()

    private let session: URLSession
    private let token: @Sendable () -> TokenStore.Read
    private let onRejected: @Sendable (String?) async -> Void

    /// The parameters are the seam for HubTokenTests - a stubbed session, a
    /// token that is not in the Keychain, and a HubToken that is not the
    /// app's. The app itself only ever uses `shared`, built from the defaults.
    init(
        session: URLSession = HubClient.defaultSession(),
        token: @escaping @Sendable () -> TokenStore.Read = { TokenStore.read() },
        onRejected: @escaping @Sendable (String?) async -> Void = HubClient.rejectShared
    ) {
        self.session = session
        self.token = token
        self.onRejected = onRejected
    }

    /// The app's own 401 handler: the shared HubToken, which RootView watches.
    static func rejectShared(_ sent: String?) async { await HubToken.shared.rejected(sent) }

    static func defaultSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false  // fail fast so "not on the tailnet" appears promptly
        return URLSession(configuration: c)
    }

    /// THE WAY BACK TO THE TOKEN SCREEN. Every 401 goes through here, so a
    /// rotated token forgets itself and RootView asks for the new one, instead
    /// of the app saying "rejected" forever with nowhere to paste a fix.
    /// `sent` is the token that request actually carried, nil when there was
    /// none - see HubToken.rejected for why that matters.
    private func unauthorized(_ sent: String?) async -> HubError {
        await onRejected(sent)
        return .unauthorized
    }

    /// Every request carries the token. A request built without it is a bug,
    /// so there is exactly one place that builds requests.
    ///
    /// No token throws .unauthorized, which every caller routes to
    /// `unauthorized(nil)` and the token screen. A LOCKED Keychain throws
    /// .locked instead, which no caller catches that way - see TokenStore.Read.
    private func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        let token: String
        switch self.token() {
        case .token(let t): token = t
        case .missing: throw HubError.unauthorized
        case .locked: throw HubError.locked
        }
        var comps = URLComponents(
            url: Config.baseURL.appending(path: path),
            resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!)
        r.setValue(token, forHTTPHeaderField: "x-rack-token")
        return r
    }

    /// URLError -> HubError. THIS MAPPING IS THE WHOLE UX of the failure path:
    /// "not on the tailnet" and "signed out" send the user to completely
    /// different fixes, and the only thing that tells them apart is this.
    private func mapped(_ error: Error) -> HubError {
        if let e = error as? HubError { return e }
        guard let u = error as? URLError else { return .http(0, error.localizedDescription) }
        switch u.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
            .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed:
            return .unreachable
        default:
            return .http(0, u.localizedDescription)
        }
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as: T.Type = T.self) async throws -> T {
        let req: URLRequest
        do { req = try request(path, query: query) } catch HubError.unauthorized { throw await unauthorized(nil) } catch { throw mapped(error) }

        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw mapped(error) }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw await unauthorized(req.value(forHTTPHeaderField: "x-rack-token")) }
        guard (200..<300).contains(code) else {
            throw HubError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw HubError.decoding("\(error)") }
    }

    // --- the endpoints, named so a caller never spells a path ---

    /// Every conversation across every source, newest first - the hub already
    /// sorts, so a caller must not re-sort and risk disagreeing with it.
    func conversations() async throws -> ConversationsPage { try await get("/api/conversations") }

    /// One transcript. `request(_:)` builds the URL with `Config.baseURL
    /// .appending(path:)`, which ALREADY percent-encodes the string it is
    /// given - so these three components must be handed over RAW. Escaping
    /// them here first (as this used to, with `.alphanumerics`) double-encodes
    /// every `-` and `_` into `%2D`/`%5F`, and `appending(path:)` re-escapes
    /// that leading `%` into `%25...` on top - the hub's session-id parser
    /// then sees neither the original id nor a sane percent-decoding of it,
    /// and 400s. Confirmed against the live hub: `%2D` round-trips to 200,
    /// `%252D` (the double-encoded form) 400s.
    ///
    /// The tradeoff this drops: a Hermes id containing a literal `/` would be
    /// read as an extra path separator rather than part of the id, since
    /// nothing here escapes it. Every id seen from the hub so far is
    /// `api_<ms>_<rand>` - no slash - so this is accepted rather than solved.
    func transcript(source: String, node: String, id: String) async throws -> Transcript {
        try await get("/api/conversations/\(source)/\(node)/\(id)")
    }

    /// Hand APNs' device token to the hub, so a turn that finishes while this
    /// phone is asleep can page it. `com.example.agents` is already on the
    /// hub's register allowlist.
    ///
    /// BUILT THROUGH `request(_:)` LIKE EVERY OTHER CALL, so the token header
    /// cannot be forgotten here - the register route is authenticated, and a
    /// POST without it 401s in a place nobody is watching (this runs from an
    /// APNs callback, with no UI to show a failure on).
    ///
    /// `environment` IS THE APNs HOST, not a build configuration. See
    /// `PushRegistrar.apsEnvironment` for why it is read off the embedded
    /// provisioning profile: a sandbox token pushed at Apple's production host
    /// answers 400 BadDeviceToken, and the hub deletes the registration as
    /// dead, so guessing it wrong erases its own evidence.
    func registerForPush(token: String, environment: String = "sandbox") async throws {
        try await postJSON(
            "/api/push/register",
            [
                "token": token,
                "env": environment,
                // The bundle id is read rather than hardcoded so a rename cannot
                // leave this registering under a name the allowlist does not know;
                // the literal is only a floor for a build with no id at all.
                "bundle": Bundle.main.bundleIdentifier ?? "com.example.agents",
            ])
    }

    /// POST a small JSON object; any 2xx is success, 401 clears the token the
    /// way every other call does, anything else is `.http(code, body)`.
    private func postJSON(_ path: String, _ body: [String: String]) async throws {
        var r: URLRequest
        do { r = try request(path) } catch HubError.unauthorized { throw await unauthorized(nil) }
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw await unauthorized(r.value(forHTTPHeaderField: "x-rack-token")) }
        guard (200..<300).contains(code) else {
            throw HubError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // --- files (the NAS pool, via the hub's allowlisted routes) ---

    private struct Uploaded: Decodable { let path: String }

    /// POST /api/files/upload - THE BYTES ARE THE BODY, not multipart; that is
    /// the route's contract. Returns the path the hub saved to. 409 = a file
    /// of that name is already there (the hub never overwrites).
    func upload(dir: String, name: String, data: Data) async throws -> String {
        var r: URLRequest
        do {
            r = try request("/api/files/upload", query: [.init(name: "path", value: dir), .init(name: "name", value: name)])
        } catch HubError.unauthorized { throw await unauthorized(nil) } catch { throw mapped(error) }
        r.httpMethod = "POST"
        r.setValue("image/jpeg", forHTTPHeaderField: "content-type")
        r.timeoutInterval = 120  // a full-size photo over LTE outlasts the 20 s default
        let body: Data
        let resp: URLResponse
        do { (body, resp) = try await session.upload(for: r, from: data) } catch { throw mapped(error) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw await unauthorized(r.value(forHTTPHeaderField: "x-rack-token")) }
        guard (200..<300).contains(code) else { throw HubError.http(code, String(data: body, encoding: .utf8) ?? "") }
        do { return try JSONDecoder().decode(Uploaded.self, from: body).path } catch { throw HubError.decoding("\(error)") }
    }

    /// GET /api/files/content - raw bytes of one file, for photo thumbnails.
    func fileData(path: String) async throws -> Data {
        let req: URLRequest
        do { req = try request("/api/files/content", query: [.init(name: "path", value: path)]) } catch HubError.unauthorized {
            throw await unauthorized(nil)
        } catch { throw mapped(error) }
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw mapped(error) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw await unauthorized(req.value(forHTTPHeaderField: "x-rack-token")) }
        guard (200..<300).contains(code) else { throw HubError.http(code, "") }
        return data
    }

    // --- mail (mailgate on atlas, relayed by the hub) ---

    func mailPending() async throws -> [MailPending] {
        try await get("/api/mail/pending", as: MailPendingPage.self).pending
    }

    /// Every kind. A hub from before texts/calendar answers 405 (it only has
    /// GET /pending), and a hub whose mailgate is older answers 404: both
    /// fall back to emails only.
    func approvalsPending() async throws -> [Approval] {
        do { return try await get("/api/mail/pending_all", as: ApprovalPage.self).pending } catch HubError.http(let code, _) where code == 404 || code == 405 {
            return try await mailPending().map(Approval.init(mail:))
        }
    }

    /// The hub relays {id, sig} to mailgate unchanged; it cannot make a sig.
    func mailApprove(id: String, sig: String) async throws {
        try await postJSON("/api/mail/approve", ["id": id, "sig": sig])
    }

    func mailCancel(id: String) async throws {
        try await postJSON("/api/mail/cancel", ["id": id])
    }

    // --- speech ---

    /// How much audio is handed on at a time: a tenth of a second of the
    /// hub's 24 kHz 16-bit mono, the size of `SpeechBatcher`'s first batch.
    static let speechPiece = 4_800

    /// `text` read aloud by Kokoro on atlas: POST /api/tts, and the audio
    /// yielded as it arrives. Little-endian 16-bit mono PCM at 24 kHz, whatever
    /// the `audio/L16` content type says; a piece can end mid-sample.
    ///
    /// Throws a `TTSError`, before any audio when the hub refuses (the hub
    /// sends its headers only once Kokoro's first audio exists), and
    /// `.torn` when the audio stops partway. Letting go of the stream cancels
    /// the request.
    ///
    /// NONISOLATED, and the bytes are read off this actor: a reading lasts
    /// as long as the answer, and every other call here would queue behind
    /// each of its pieces.
    nonisolated func speech(_ text: String, voice: String? = nil) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try await self.speechRequest(text, voice: voice)
                    try await Self.read(
                        speech: request, on: self.session, rejecting: self.onRejected,
                        into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The POST, token and all. A missing token is the token screen, as for
    /// every call; a LOCKED one only fails this reading (ec939fa).
    private func speechRequest(_ text: String, voice: String?) async throws -> URLRequest {
        var r: URLRequest
        do { r = try request("/api/tts") } catch HubError.unauthorized {
            _ = await unauthorized(nil)
            throw TTSError.unauthorized
        } catch HubError.locked { throw TTSError.locked }
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        // SHORTER THAN THE SESSION'S 20 s, because this is a chunk of at
        // most 40 words - about 8 s of synthesis on atlas, and the hub sends
        // its headers as soon as Kokoro's first audio exists. Longer than
        // that is not slow, it is gone, and every second of it is silence
        // with the mic open.
        r.timeoutInterval = 12
        var body = ["text": text]
        if let voice { body["voice"] = voice }
        r.httpBody = try JSONEncoder().encode(body)
        return r
    }

    /// Yields the answer's bytes in pieces of `speechPiece`, and the rest at
    /// the end: or at a tear, so what did arrive still plays.
    ///
    /// ONE BYTE AT A TIME, off `AsyncBytes`'s own buffer. At about 72 KB a
    /// second at most, that is nothing.
    private static func read(
        speech r: URLRequest, on session: URLSession,
        rejecting rejected: @Sendable (String?) async -> Void,
        into continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: r) } catch {
            throw Task.isCancelled ? CancellationError() : TTSError.unreachable
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300:
            // AUDIO, OR IT IS NOT SPEECH. Anything else - a proxy's page, a
            // hub without the route answering JSON - decoded as PCM is a
            // burst of noise played at full volume.
            let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "content-type") ?? ""
            guard type.lowercased().hasPrefix("audio/") else {
                Logger.voice.error("Voice: /api/tts answered \(type.isEmpty ? "no content type" : type, privacy: .public), not audio")
                throw TTSError.refused((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
        case 401:
            await rejected(r.value(forHTTPHeaderField: "x-rack-token"))
            throw TTSError.unauthorized
        case 429: throw TTSError.busy
        case 502: throw TTSError.unavailable
        case let code: throw TTSError.refused(code)
        }
        var piece = Data(capacity: speechPiece)
        do {
            for try await byte in bytes {
                piece.append(byte)
                if piece.count >= speechPiece {
                    continuation.yield(piece)
                    piece = Data(capacity: speechPiece)
                }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if !piece.isEmpty { continuation.yield(piece) }
            throw TTSError.torn
        }
        if !piece.isEmpty { continuation.yield(piece) }
    }

    /// Prove a token before `TokenEntryView` commits it to the Keychain. A typo
    /// stored would 401 on the first call and bounce straight back to that
    /// screen (see `unauthorized`), and over "Change token" it would already
    /// have replaced a token that worked.
    ///
    /// `nonisolated`, and deliberately NOT built through `request(_:)`: the
    /// token being tested is not in the Keychain yet, and `request` reads it
    /// from there. It also uses `URLSession.shared` rather than the actor's own
    /// session for the same reason - there is no actor state involved here.
    ///
    /// HITS /api/conversations, NOT /api/apps like rack-control's copy does.
    /// A credential proved against an endpoint this app never calls is a weaker
    /// check: it would pass while the one thing Agents actually needs still
    /// 401s. Prove it against the endpoint the app opens on.
    nonisolated func validate(_ token: String) async -> Bool {
        var r = URLRequest(url: Config.baseURL.appending(path: "/api/conversations"))
        r.setValue(token, forHTTPHeaderField: "x-rack-token")
        r.timeoutInterval = 15
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
