import Foundation

/// One event off POST /api/claude, POST /api/hermes or GET /api/turns/attach.
/// All three speak the SAME SSE vocabulary - `conversation`, then `text`...,
/// then a terminal `done` - which is why one stream reader serves all of them.
/// Hermes simply never emits `tool`/`tool_result`, and its `done` carries no
/// `denials`.
struct SSEEvent: Sendable {
    let event: String
    let data: Data
    /// The hub's `id:` field, present on every event it BUFFERS and absent on
    /// `conversation`, which is per-connection metadata rather than turn
    /// content. This is what a client hands back as `from` after the phone has
    /// been asleep, so losing track of it means replaying an answer into a
    /// bubble that already holds half of it.
    let seq: Int?
}

/// The hub's SSE payloads, decoded.
struct ClaudeConversation: Codable, Sendable { let conversation: String }
struct ClaudeText: Codable, Sendable { let text: String }
struct ClaudeTool: Codable, Sendable {
    let id: String
    let name: String
    let summary: String
}
struct ClaudeToolResult: Codable, Sendable {
    let id: String
    let text: String
}
struct ClaudeDone: Codable, Sendable {
    let error: String?
    let denials: [String]?
}

enum ClaudeError: LocalizedError, Sendable {
    case busy  // 409 - this conversation is mid-turn
    case hubBusy  // 429 - the hub is at its concurrent-turn cap
    case gone  // 404 - the conversation was evicted or never existed
    case tooLong  // 400/413
    case unauthorized
    case unreachable
    /// The phone is locked and the Keychain will not give up the token - see
    /// TokenStore.Read. Not .unauthorized: the token is fine.
    case locked
    case other(String)

    var errorDescription: String? {
        switch self {
        case .busy: "Still answering."
        case .hubBusy: "The hub is busy with other turns. Try again in a moment."
        case .gone: "That conversation expired. Starting a new one."
        case .tooLong: "That message was too long."
        case .unauthorized: "That token was rejected."
        case .unreachable: "Can't reach the rack. Is Tailscale connected?"
        case .locked: "The phone is locked. Unlock it, then try again."
        case .other(let m): m
        }
    }
}

/// Which hub endpoint a turn goes to.
///
/// `Hashable` so `ChatTarget` can be - the shell drives SwiftUI's `.id()` with
/// that value, and `.id()` takes a `Hashable`. The two Hermes boxes differ
/// only by their associated `node`, so synthesized conformance is exactly
/// right here: without it they would compare equal and switching between them
/// would leave the previous chat on screen.
enum Agent: Sendable, Hashable {
    case claude
    case hermes(node: String)

    var path: String {
        switch self {
        case .claude: "/api/claude"
        case .hermes: "/api/hermes"
        }
    }

    /// The seam that turns "the id I got back from the `conversation` SSE
    /// event" into "what the NEXT turn in this thread must send" - the one
    /// place that knows which of the hub's two keys each agent expects, so a
    /// call site never has to remember it.
    ///
    /// Claude hands back a hub-minted `conversation` id on that event; every
    /// later turn in the thread must send it as `conversation`, never as
    /// `sessionId` again (see `Attach` below). Hermes has no separate
    /// conversation concept at all - what arrives in that same event IS its
    /// session id, so it becomes next turn's `sessionId`.
    func attach(afterConversationEvent id: String) -> Attach {
        switch self {
        case .claude: .conversation(id)
        case .hermes: .sessionId(id)
        }
    }
}

/// How a turn attaches to an existing thread, if at all. The hub accepts
/// `sessionId` and `conversation` as two different JSON keys, but they are
/// cases of ONE enum here rather than two Optional parameters - so "send
/// both" cannot even be written at a call site, let alone reach the wire.
/// Exactly one of "nothing", "a session id", or "a hub-minted conversation
/// id" is ever live.
enum Attach: Sendable {
    /// No thread yet. The hub starts a fresh one and hands back its id on the
    /// `conversation` event.
    case none
    /// Opens or resumes a thread by an agent-native session id. For Claude
    /// this is valid ONLY on the first message of a resumed thread - use
    /// `Agent.attach(afterConversationEvent:)` for every turn after that.
    /// For Hermes this is valid on every turn, first or later.
    case sessionId(String)
    /// A hub-minted id from a prior `conversation` event. Claude only - the
    /// hub's `/api/hermes` route does not read this key at all.
    case conversation(String)
}

enum SSEStream {
    /// A Claude turn can legitimately think for minutes, so this session's
    /// RESOURCE timeout is ten. The 60s default would kill a good turn.
    /// The request timeout stays short - that one is about first byte, and the
    /// hub sends `event: conversation` immediately.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    /// POST a message and yield each SSE event as it arrives.
    ///
    /// THE CONTRACT LIVES HERE, in one place, deliberately: `attach` is an
    /// `Attach`, not two Optional strings, so "send both `conversation` and
    /// `sessionId`" is not a state this function can even be asked to build -
    /// see `Attach`'s doc comment.
    ///
    /// Throws before yielding anything if the hub refuses the request, so a
    /// caller can distinguish "never started" from "died halfway".
    static func send(to agent: Agent, message: String, attach: Attach) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let token: String
                do { token = try await Self.token() } catch {
                    continuation.finish(throwing: error)
                    return
                }
                var r = URLRequest(url: Config.baseURL.appending(path: agent.path))
                r.httpMethod = "POST"
                r.setValue(token, forHTTPHeaderField: "x-rack-token")
                r.setValue("application/json", forHTTPHeaderField: "content-type")
                var body: [String: Any] = ["message": message]
                switch attach {
                case .none: break
                case .sessionId(let s): body["sessionId"] = s
                case .conversation(let c): body["conversation"] = c
                }
                if case .hermes(let node) = agent { body["node"] = node }
                r.httpBody = try? JSONSerialization.data(withJSONObject: body)

                await read(r, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Rejoin a turn this client stopped watching - the screen locked, the app
    /// went to the background, Tailscale dropped. `from` is one past the last
    /// `seq` actually rendered.
    ///
    /// THIS IS WHY THE HUB BUFFERS AT ALL. iOS suspends a backgrounded app
    /// within seconds and its socket dies; before the hub learned to detach, a
    /// locked screen SIGTERMed the turn behind it. There is no
    /// background-URLSession alternative either - background sessions do not
    /// stream, they hand back a finished file - so re-attaching on the way back
    /// is the whole mechanism.
    static func attach(conversation: String, from: Int) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let token: String
                do { token = try await Self.token() } catch {
                    continuation.finish(throwing: error)
                    return
                }
                guard
                    var c = URLComponents(
                        url: Config.baseURL.appending(path: "/api/turns/attach"),
                        resolvingAgainstBaseURL: false)
                else {
                    continuation.finish(throwing: ClaudeError.unreachable)
                    return
                }
                c.queryItems = [
                    .init(name: "conversation", value: conversation),
                    .init(name: "from", value: String(from)),
                ]
                guard let u = c.url else {
                    continuation.finish(throwing: ClaudeError.unreachable)
                    return
                }
                var r = URLRequest(url: u)
                r.setValue(token, forHTTPHeaderField: "x-rack-token")
                await read(r, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stop a turn on purpose.
    ///
    /// EXPLICIT, BECAUSE HANGING UP NO LONGER STOPS ANYTHING. Walking away from
    /// a turn used to kill it by closing the socket; that is exactly the
    /// behaviour that made a locked phone lose its answer, so leaving a turn
    /// now needs this. Fire-and-forget: the turn ending is observed through the
    /// stream like any other ending, and a cancel that does not land costs at
    /// most one turn timeout.
    static func cancel(conversation: String) async {
        // Missing or locked alike: nothing can be sent, and neither is a
        // reason to touch HubToken. A lock-screen Cancel still lands once the
        // phone has been unlocked since it restarted - see TokenStore.save.
        guard let token = TokenStore.load() else { return }
        var r = URLRequest(url: Config.baseURL.appending(path: "/api/turns/cancel"))
        r.httpMethod = "POST"
        r.setValue(token, forHTTPHeaderField: "x-rack-token")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["conversation": conversation])
        _ = try? await session.data(for: r)
    }

    /// The stored token for a send or an attach, or the error that ends it.
    ///
    /// MISSING AND LOCKED PART HERE. No token at all means the other app
    /// cleared the shared one - the same way back as a 401, see
    /// HubToken.rejected. A LOCKED Keychain means the token is there and the
    /// phone will not decrypt it yet; sending that to `rejected` is what put a
    /// lock-screen voice question on the token screen, so it only fails this
    /// request.
    private static func token() async throws -> String {
        switch TokenStore.read() {
        case .token(let t):
            return t
        case .missing:
            await HubToken.shared.rejected(nil)
            throw ClaudeError.unauthorized
        case .locked:
            throw ClaudeError.locked
        }
    }

    /// The SSE reader both entry points share. ONE parser, deliberately: a
    /// second copy is a second place for the `id:`/heartbeat handling to drift,
    /// and a re-attached stream must be folded into the transcript by exactly
    /// the same rules as the original.
    private static func read(
        _ r: URLRequest,
        into continuation: AsyncThrowingStream<SSEEvent, Error>.Continuation
    ) async {
        do {
            let (bytes, resp) = try await session.bytes(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // A rotated token: forget it and go back to the token screen,
            // exactly as HubClient does - see HubClient.unauthorized.
            if code == 401 { await HubToken.shared.rejected(r.value(forHTTPHeaderField: "x-rack-token")) }
            guard code == 200 else {
                continuation.finish(throwing: statusError(code))
                return
            }

            var event = "message"
            var seq: Int?
            // `.lines` reassembles across chunk boundaries, which is the
            // whole problem SSE parsers usually get wrong.
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                if line.isEmpty { continue }
                // The hub sends `:` comment heartbeats every 15s so iOS
                // does not time the connection out mid-think. Skipping
                // them is NOT optional - each one would otherwise render
                // as an empty bubble.
                if line.hasPrefix(":") { continue }
                if line.hasPrefix("id: ") {
                    seq = Int(line.dropFirst(4))
                    continue
                }
                if line.hasPrefix("event: ") {
                    event = String(line.dropFirst(7))
                    continue
                }
                if line.hasPrefix("data: ") {
                    continuation.yield(SSEEvent(event: event, data: Data(line.dropFirst(6).utf8), seq: seq))
                    // RESET PER FRAME. `id:` is absent on `conversation` and on
                    // any future unnumbered event; carrying the previous
                    // frame's number into one of those would make a client
                    // resume from a seq it never rendered.
                    seq = nil
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: mapped(error))
        }
    }

    private static func statusError(_ code: Int) -> ClaudeError {
        switch code {
        case 401: .unauthorized
        case 404: .gone
        case 409: .busy
        case 429: .hubBusy
        case 400, 413: .tooLong
        default: .other("The hub answered \(code).")
        }
    }

    private static func mapped(_ error: Error) -> ClaudeError {
        if let e = error as? ClaudeError { return e }
        guard let u = error as? URLError else { return .other(error.localizedDescription) }
        switch u.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
            .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed:
            return .unreachable
        case .cancelled:
            return .other("Cancelled.")
        default:
            return .other(u.localizedDescription)
        }
    }
}

/// The three hub calls a turn is made of, as values a `ChatModel` is handed.
///
/// `SSEStream`'s functions are static and cannot be swapped, and a turn's
/// whole life - the send, the socket dying, the backoff, the re-attach, the
/// Stop - happens inside `ChatModel.run`. This is how a test drives that loop
/// with streams it controls: `.live` is the app's, everything else is a fake.
/// `@MainActor` closures because the model is, and because a fake keeps its
/// bookkeeping there too.
struct Streams {
    var send: @MainActor (Agent, String, Attach) -> AsyncThrowingStream<SSEEvent, Error>
    var attach: @MainActor (_ conversation: String, _ from: Int) -> AsyncThrowingStream<SSEEvent, Error>
    var cancel: @MainActor (_ conversation: String) async -> Void

    static var live: Streams {
        Streams(
            send: { SSEStream.send(to: $0, message: $1, attach: $2) },
            attach: { SSEStream.attach(conversation: $0, from: $1) },
            cancel: { await SSEStream.cancel(conversation: $0) })
    }
}
