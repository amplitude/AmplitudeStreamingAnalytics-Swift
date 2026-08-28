import Foundation
import XCTest

/// Swift-side view of `tools/mock_delayed_server.py`'s debug API — what the server *saw*, as
/// opposed to what the SDK believes it sent.
///
/// Everything here is synchronous on purpose: a contract test drives the tracker, waits for
/// the server to have observed something, and asserts. The waits poll rather than subscribe,
/// because the mock has no push channel and the alternative (sleep-then-assert) is flakier.
///
/// Shapes follow the mock's documented debug payloads; see its module docstring. The request
/// log is a published interface over there, so a rename on either side should break loudly
/// here.
struct MockDelayedServer {
    static let defaultBaseUrl = URL(string: "http://127.0.0.1:8123")!

    /// Contract tests run only when the harness says a server is up (`MOCK_SERVER=1`).
    /// Under `xcodebuild test` on a simulator the shell environment does not reach the test
    /// process, so in practice this gates them to the macOS `swift test` job.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MOCK_SERVER"] == "1"
    }

    let baseUrl: URL

    init(baseUrl: URL = MockDelayedServer.defaultBaseUrl) {
        self.baseUrl = baseUrl
    }

    var delayedEndpointServerUrl: String {
        // The client appends "/delayed" itself, so this is what a Configuration takes.
        baseUrl.appendingPathComponent("2").appendingPathComponent("httpapi").absoluteString
    }

    // MARK: - Debug reads

    func isHealthy() -> Bool {
        (try? get("/healthcheck", as: Health.self))?.status == "ok"
    }

    func reset() throws {
        _ = try send(method: "POST", path: "/debug/reset", body: nil, as: ResetResponse.self)
    }

    /// `GET /debug/requests` — the request log, oldest first, completed requests only.
    /// **This is where assertions belong.**
    func requests() throws -> [Request] {
        try get("/debug/requests", as: RequestLog.self).requests
    }

    /// `GET /debug/state` — the payloads the mock is holding.
    ///
    /// Exposed for parity with the mock's surface (the demo app's debug panel reads it), and
    /// deliberately *not* used by any assertion: the mock documents this as a convenience for
    /// a human watching the demo app, not a model of backend storage. Asserting on it would be
    /// testing the fixture. What the SDK controls is in `requests()`.
    func state() throws -> StateSnapshot {
        try get("/debug/state", as: StateSnapshot.self)
    }

    // MARK: - Scripted responses

    /// Queues responses for subsequent `POST /2/httpapi/delayed` requests, consumed one per
    /// request in order; normal behaviour resumes once the queue drains.
    ///
    /// Validation runs *before* the queue is consumed, so a scripted failure still proves the
    /// body that provoked it was one the endpoint accepts.
    @discardableResult
    func queueScript(_ responses: [ScriptedResponse]) throws -> Int {
        let payload = try JSONEncoder().encode(ScriptRequest(queue: responses))
        return try send(method: "POST", path: "/debug/script", body: payload,
                        as: ScriptQueuedResponse.self).queued
    }

    /// `GET /debug/script` — the entries still queued, verbatim as they were posted.
    func pendingScript() throws -> [[String: JSONValue]] {
        try get("/debug/script", as: ScriptSnapshot.self).queue
    }

    // MARK: - Waits

    @discardableResult
    func waitForRequests(_ count: Int, timeout: TimeInterval = 5,
                         file: StaticString = #filePath, line: UInt = #line) throws -> [Request] {
        try waitFor("\(count) request(s)", timeout: timeout, file: file, line: line) {
            let observed = try requests()
            return observed.count >= count ? observed : nil
        }
    }

    /// Waits for the first logged request matching `matches`.
    ///
    /// Prefer this over indexing `waitForRequests(n)` whenever the request count is not fully
    /// determined by the SDK. Two tracks landing in the same tick may coalesce into one request
    /// (the tracker defers each send by a queue hop), and `URLSession` transparently re-sends a
    /// request when a pooled connection dies before any response bytes arrive — so a scripted
    /// hang-up can show up at the server twice for one tracker send. Matching on contents is
    /// immune to both; matching on an index is not.
    @discardableResult
    func waitForRequest(_ description: String, timeout: TimeInterval = 5,
                        file: StaticString = #filePath, line: UInt = #line,
                        matching matches: (Request) -> Bool) throws -> Request {
        try waitFor(description, timeout: timeout, file: file, line: line) {
            try requests().first(where: matches)
        }
    }

    /// Asserts the log stays at `count` entries for `settleFor` seconds — the only honest way to
    /// test that something sends *nothing*, since "not yet" and "never" look identical to a poll.
    func expectNoMoreRequests(beyond count: Int, settleFor: TimeInterval = 0.5,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(settleFor)
        repeat {
            let observed = try requests()
            guard observed.count <= count else {
                XCTFail("Expected no request beyond #\(count), but the server logged "
                        + "\(observed.count): \(observed.map(\.summary))", file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
    }

    /// Polls `produce` until it returns non-nil. `produce` may throw only for real transport
    /// failures — a not-yet condition must be expressed as `nil`, not as a throw.
    func waitFor<T>(_ description: String, timeout: TimeInterval = 5,
                    pollInterval: TimeInterval = 0.02,
                    file: StaticString = #filePath, line: UInt = #line,
                    produce: () throws -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        var last: T?
        repeat {
            last = try produce()
            if let last { return last }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        XCTFail("Timed out after \(timeout)s waiting for \(description)", file: file, line: line)
        throw MockServerError.timedOut(description)
    }

    /// Asserts the tracker never sent anything the server refused. Cheap to call in teardown,
    /// and it is the assertion that actually protects the wire format: a body the SDK is happy
    /// with but the endpoint rejects shows up here and nowhere else.
    ///
    /// Scripted entries are exempt. A scripted status is chosen by the test, and the mock runs
    /// its real validation *before* consuming the queue, so a scripted 500 or hang-up is not
    /// the endpoint refusing the body — it is the test asking for a failure the body was
    /// already good enough to have avoided.
    func assertNoRejectedRequests(file: StaticString = #filePath, line: UInt = #line) throws {
        let rejected = try requests().filter { !$0.scripted && $0.status != 200 }
        for entry in rejected {
            XCTFail("Server rejected request #\(entry.seq) with HTTP \(entry.status): "
                    + "\(entry.error ?? "no error string")", file: file, line: line)
        }
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, as type: T.Type) throws -> T {
        try send(method: "GET", path: path, body: nil, as: type)
    }

    private func send<T: Decodable>(method: String, path: String, body: Data?,
                                    as type: T.Type) throws -> T {
        var urlRequest = URLRequest(url: baseUrl.appendingPathComponent(path), timeoutInterval: 5)
        urlRequest.httpMethod = method
        if let body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(MockServerError.noResponse)
        // URLSession calls back on its own queue, so waiting on the calling thread is safe.
        URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                result = .failure(MockServerError.unexpectedStatus(status, path: path))
                return
            }
            result = .success(data ?? Data())
        }.resume()

        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw MockServerError.noResponse
        }
        return try JSONDecoder().decode(type, from: try result.get())
    }
}

enum MockServerError: Error, CustomStringConvertible {
    case noResponse
    case unexpectedStatus(Int, path: String)
    case timedOut(String)

    var description: String {
        switch self {
        case .noResponse:
            return "mock server did not respond"
        case .unexpectedStatus(let status, let path):
            return "mock server returned HTTP \(status) for \(path)"
        case .timedOut(let what):
            return "timed out waiting for \(what)"
        }
    }
}

// MARK: - Debug payloads

extension MockDelayedServer {
    private struct Health: Decodable {
        let status: String
    }

    private struct ResetResponse: Decodable {
        let reset: Bool
    }

    private struct RequestLog: Decodable {
        let count: Int
        let requests: [Request]
    }

    private struct ScriptRequest: Encodable {
        let queue: [ScriptedResponse]
    }

    private struct ScriptQueuedResponse: Decodable {
        let queued: Int
    }

    private struct ScriptSnapshot: Decodable {
        let queue: [[String: JSONValue]]
    }

    /// One queued entry for `POST /debug/script`. `nil` fields are omitted, letting the mock
    /// apply its own defaults (status 200, empty body).
    struct ScriptedResponse: Encodable {
        var status: Int?
        var body: [String: JSONValue]?
        var close: Bool?

        /// An HTTP status the client will see, with an optional response body.
        ///
        /// Careful with scripted *successes*: `DelayedEventsHttpClient` decodes a 2xx body into
        /// `DelayedResponseBody`, whose `id` is non-optional, and turns a decode failure into
        /// `.failure`. A bare `.status(200)` therefore reaches the SDK as an error, not a
        /// success. A scripted success must supply a real body, e.g.
        /// `["code": .number(200), "id": .string(delayId), "flushed": .bool(true)]`.
        static func status(_ status: Int, body: [String: JSONValue]? = nil) -> ScriptedResponse {
            ScriptedResponse(status: status, body: body, close: nil)
        }

        /// Hangs up without responding, so the client sees a transport error rather than a status.
        static let hangUp = ScriptedResponse(status: nil, body: nil, close: true)
    }

    /// `GET /debug/state`. Modelled for completeness only — see `state()`; do not assert on it.
    struct StateSnapshot: Decodable {
        let count: Int
        let entries: [Entry]

        struct Entry: Decodable {
            let apiKey: String?
            let id: String?
            let timeout: Int64?
            let events: [MockEvent]
            let storedAt: Int64

            enum CodingKeys: String, CodingKey {
                case apiKey = "api_key"
                case id
                case timeout
                case events
                case storedAt = "stored_at"
            }
        }
    }

    /// One entry of `GET /debug/requests`.
    struct Request: Decodable {
        /// What the server did, in order. Mirrors the mock's documented vocabulary.
        enum Action: String, Decodable {
            case store
            case flush
            case drop
            case sink
            case closed
            case unhandled
        }

        let seq: Int
        let receivedAt: Int64
        let method: String
        let path: String
        /// The status the mock returned, or 0 when it hung up without responding.
        let status: Int
        let apiKey: String?
        let id: String?
        let timeout: Int64?
        let events: [MockEvent]
        let instantEvents: [MockEvent]
        /// The whole parsed request body, verbatim. Asserting on its key set is what catches a
        /// renamed `CodingKey` in `DelayedRequestBody`.
        let body: [String: JSONValue]?
        let rawBody: String?
        let response: [String: JSONValue]?
        let error: String?
        let scripted: Bool
        let actions: [Action]

        var eventInsertIds: [String] { events.compactMap(\.insertId) }
        var instantInsertIds: [String] { instantEvents.compactMap(\.insertId) }

        /// Top-level keys of the body as received. `nil` when the body did not parse.
        var bodyKeys: Set<String>? { body.map { Set($0.keys) } }

        var summary: String {
            "#\(seq) \(method) \(path) -> \(status)"
                + " events=\(eventInsertIds) instant=\(instantInsertIds)"
                + " timeout=\(timeout.map(String.init) ?? "nil") actions=\(actions.map(\.rawValue))"
        }

        enum CodingKeys: String, CodingKey {
            case seq
            case receivedAt = "received_at"
            case method
            case path
            case status
            case apiKey = "api_key"
            case id
            case timeout
            case events
            case instantEvents = "instant_events"
            case body
            case rawBody = "raw_body"
            case response
            case error
            case scripted
            case actions
        }
    }
}

/// An event as the server saw it. Kept as raw JSON rather than decoded into `BaseEvent`:
/// decoding through the SDK's own type would hide exactly the field-name mismatches these
/// tests exist to catch.
struct MockEvent: Decodable {
    let raw: [String: JSONValue]

    var eventType: String? { raw["event_type"]?.stringValue }
    var insertId: String? { raw["insert_id"]?.stringValue }
    var time: JSONValue? { raw["time"] }

    init(raw: [String: JSONValue]) {
        self.raw = raw
    }

    init(from decoder: Decoder) throws {
        raw = try [String: JSONValue](from: decoder)
    }
}

/// Just enough JSON to assert on — and to script — payloads the SDK does not own the shape of.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int64? {
        if case .number(let value) = self { return Int64(value) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
