import Foundation
import XCTest

/// Swift-side view of `tools/mock_delayed_server.py`'s debug API — what the server *did*,
/// as opposed to what the SDK believes it sent.
///
/// Everything here is synchronous on purpose: a contract test drives the tracker, waits for
/// the server to have observed something, and asserts. The waits poll rather than subscribe,
/// because the mock has no push channel and the alternative (sleep-then-assert) is flakier.
///
/// Shapes follow the mock's documented debug payloads; see its module docstring. They are a
/// published interface over there, so a rename on either side should break loudly here.
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
        _ = try request(method: "POST", path: "/debug/reset", as: ResetResponse.self)
    }

    func requests() throws -> [Request] {
        try get("/debug/requests", as: RequestLog.self).requests
    }

    func ingested() throws -> [IngestBatch] {
        try get("/debug/ingested", as: IngestLog.self).ingested
    }

    func rows() throws -> [Row] {
        try get("/debug/state", as: StateSnapshot.self).rows
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

    @discardableResult
    func waitForIngested(_ count: Int, timeout: TimeInterval = 5,
                         file: StaticString = #filePath, line: UInt = #line) throws -> [IngestBatch] {
        try waitFor("\(count) ingest batch(es)", timeout: timeout, file: file, line: line) {
            let observed = try ingested()
            return observed.count >= count ? observed : nil
        }
    }

    @discardableResult
    func waitForRows(_ count: Int, timeout: TimeInterval = 5,
                     file: StaticString = #filePath, line: UInt = #line) throws -> [Row] {
        try waitFor("\(count) stored row(s)", timeout: timeout, file: file, line: line) {
            let observed = try rows()
            return observed.count == count ? observed : nil
        }
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
    func assertNoRejectedRequests(file: StaticString = #filePath, line: UInt = #line) throws {
        let rejected = try requests().filter { $0.status != 200 }
        for entry in rejected {
            XCTFail("Server rejected request #\(entry.seq) with HTTP \(entry.status): "
                    + "\(entry.error ?? "no error string")", file: file, line: line)
        }
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, as type: T.Type) throws -> T {
        try request(method: "GET", path: path, as: type)
    }

    private func request<T: Decodable>(method: String, path: String, as type: T.Type) throws -> T {
        var urlRequest = URLRequest(url: baseUrl.appendingPathComponent(path), timeoutInterval: 5)
        urlRequest.httpMethod = method

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

    private struct IngestLog: Decodable {
        let count: Int
        let ingested: [IngestBatch]
    }

    private struct StateSnapshot: Decodable {
        let count: Int
        let rows: [Row]
    }

    /// One entry of `GET /debug/requests`.
    struct Request: Decodable {
        /// What the server did, in order. Mirrors the mock's documented vocabulary.
        enum Action: String, Decodable {
            case upsert
            case ingestInstant = "ingest_instant"
            case flush
            case delete
            case ingestDirect = "ingest_direct"
            case unhandled
        }

        let seq: Int
        let receivedAt: Int64
        let method: String
        let path: String
        let status: Int
        let apiKey: String?
        let id: String?
        let timeout: Int64?
        let events: [MockEvent]
        let instantEvents: [MockEvent]
        let response: [String: JSONValue]?
        let error: String?
        let actions: [Action]

        var eventInsertIds: [String] { events.compactMap(\.insertId) }
        var instantInsertIds: [String] { instantEvents.compactMap(\.insertId) }

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
            case response
            case error
            case actions
        }
    }

    /// One entry of `GET /debug/ingested` — a batch that reached the (simulated) event API.
    struct IngestBatch: Decodable {
        enum Trigger: String, Decodable {
            case instant
            case flush
            case ttl
            case direct
        }

        let seq: Int
        let at: Int64
        let trigger: Trigger
        let requestSeq: Int?
        let apiKey: String?
        let id: String?
        let eventCount: Int
        let events: [MockEvent]

        var insertIds: [String] { events.compactMap(\.insertId) }

        enum CodingKeys: String, CodingKey {
            case seq
            case at
            case trigger
            case requestSeq = "request_seq"
            case apiKey = "api_key"
            case id
            case eventCount = "event_count"
            case events
        }
    }

    /// One stored row of `GET /debug/state` — one DynamoDB item in the real service.
    struct Row: Decodable {
        let id: String
        let apiKey: String
        let delayId: String
        let orgId: Int
        let timeoutMs: Int64
        let createdAt: Int64
        let updatedAt: Int64
        let expiration: Int64
        let eventData: [String: JSONValue]

        /// The delayed events the server is holding, i.e. what TTL expiry would ingest.
        var storedEvents: [MockEvent] {
            guard case .array(let values)? = eventData["events"] else { return [] }
            return values.compactMap { value in
                guard case .object(let fields) = value else { return nil }
                return MockEvent(raw: fields)
            }
        }

        var storedInsertIds: [String] { storedEvents.compactMap(\.insertId) }

        /// Whether the stored body still carries `instant_events`, which it must not when the
        /// request that wrote it had any.
        var storedInstantEvents: JSONValue? { eventData["instant_events"] }

        enum CodingKeys: String, CodingKey {
            case id
            case apiKey = "api_key"
            case delayId = "delay_id"
            case orgId = "org_id"
            case timeoutMs = "timeout_ms"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case expiration
            case eventData = "event_data"
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

/// Just enough JSON to assert on payloads the SDK does not own the shape of.
enum JSONValue: Decodable, Equatable {
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
}
