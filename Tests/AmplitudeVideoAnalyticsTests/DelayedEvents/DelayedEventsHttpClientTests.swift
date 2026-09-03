import XCTest
@testable import AmplitudeVideoAnalytics
import AmplitudeSwift

final class DelayedEventsHttpClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    // MARK: - getUrl()

    func testGetUrlDefaultsToUSDelayedHost() {
        let client = DelayedEventsHttpClient(configuration: Configuration(apiKey: "test-key"))
        XCTAssertEqual(client.getUrl(), "https://api2.amplitude.com/2/httpapi/delayed")
    }

    func testGetUrlUsesEUDelayedHost() {
        let config = Configuration(apiKey: "test-key", serverZone: .EU)
        XCTAssertEqual(DelayedEventsHttpClient(configuration: config).getUrl(),
                       "https://api.eu.amplitude.com/2/httpapi/delayed")
    }

    func testGetUrlAppendsDelayedToCustomServerUrl() {
        let config = Configuration(apiKey: "test-key", serverUrl: "http://localhost:8123/2/httpapi")
        XCTAssertEqual(DelayedEventsHttpClient(configuration: config).getUrl(),
                       "http://localhost:8123/2/httpapi/delayed")
    }

    func testGetUrlHandlesTrailingSlashCustomServerUrl() {
        let config = Configuration(apiKey: "test-key", serverUrl: "http://localhost:8123/2/httpapi/")
        XCTAssertEqual(DelayedEventsHttpClient(configuration: config).getUrl(),
                       "http://localhost:8123/2/httpapi/delayed")
    }

    // MARK: - request/response body contract

    func testRequestBodyEncodesContractShape() throws {
        let event = BaseEvent(eventType: "Video Content Stopped")
        event.insertId = "ins-1"
        event.timestamp = 1_752_000_000_000
        let body = DelayedRequestBody(apiKey: "k", id: "d-1", ttlMs: 3_600_000,
                                      events: [event], instantEvents: nil)
        // swiftlint:disable:next force_cast
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String: Any]
        XCTAssertEqual(json["api_key"] as? String, "k")
        XCTAssertEqual(json["id"] as? String, "d-1")
        XCTAssertEqual((json["timeout"] as? NSNumber)?.int64Value, 3_600_000)
        // swiftlint:disable:next force_cast
        let events = json["events"] as! [[String: Any]]
        XCTAssertEqual(events[0]["event_type"] as? String, "Video Content Stopped")
        XCTAssertEqual(events[0]["insert_id"] as? String, "ins-1")
        XCTAssertEqual((events[0]["time"] as? NSNumber)?.int64Value, 1_752_000_000_000)
        XCTAssertNil(json["instant_events"])
    }

    func testResponseBodyDecodesStoredAndFlushedShapes() throws {
        let storedData = Data(#"{"id":"d-1","expiration":1752000000}"#.utf8)
        let stored = try JSONDecoder().decode(DelayedResponseBody.self, from: storedData)
        XCTAssertEqual(stored, DelayedResponseBody(id: "d-1", expiration: 1_752_000_000, flushed: nil))

        let flushedData = Data(#"{"id":"d-2","flushed":true}"#.utf8)
        let flushed = try JSONDecoder().decode(DelayedResponseBody.self, from: flushedData)
        XCTAssertEqual(flushed, DelayedResponseBody(id: "d-2", expiration: nil, flushed: true))
    }

    // MARK: - upload() completion handler (via injected URLProtocol stub)

    private func makeStubbedClient() -> DelayedEventsHttpClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return DelayedEventsHttpClient(configuration: Configuration(apiKey: "test-key"),
                                       urlSessionConfiguration: config)
    }

    private func makeBody() -> DelayedRequestBody {
        DelayedRequestBody(apiKey: "test-key", id: "d-1", ttlMs: 3_600_000,
                           events: [BaseEvent(eventType: "Video Content Stopped")], instantEvents: nil)
    }

    func testUploadSuccessDecodesResponseBody() {
        StubURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            return StubURLProtocol.StubResponse(response: response,
                                                data: Data(#"{"id":"d-1","expiration":1752000000}"#.utf8))
        }
        let exp = expectation(description: "success")
        let task = makeStubbedClient().upload(makeBody()) { result in
            switch result {
            case .success(let body):
                XCTAssertEqual(body.id, "d-1")
                XCTAssertEqual(body.expiration, 1_752_000_000)
                XCTAssertNil(body.flushed)
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            }
            exp.fulfill()
        }
        XCTAssertNotNil(task)
        waitForExpectations(timeout: 5)
    }

    func testUploadHTTPErrorSurfacesHttpError() {
        StubURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)
            return StubURLProtocol.StubResponse(response: response, data: Data("boom".utf8))
        }
        let exp = expectation(description: "http error")
        makeStubbedClient().upload(makeBody()) { result in
            guard case .failure(let error) = result,
                  case DelayedEventsError.httpError(let code, _) = error else {
                return XCTFail("expected httpError, got \(result)")
            }
            XCTAssertEqual(code, 500)
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testUploadTransportErrorSurfacesError() {
        StubURLProtocol.responder = { _ in
            StubURLProtocol.StubResponse(error: NSError(domain: NSURLErrorDomain,
                                                        code: NSURLErrorNotConnectedToInternet))
        }
        let exp = expectation(description: "transport error")
        makeStubbedClient().upload(makeBody()) { result in
            guard case .failure(let error) = result else {
                return XCTFail("expected failure, got \(result)")
            }
            XCTAssertEqual((error as NSError).code, NSURLErrorNotConnectedToInternet)
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testUploadNonHTTPResponseSurfacesInvalidResponse() {
        StubURLProtocol.responder = { request in
            let response = URLResponse(url: request.url!, mimeType: nil,
                                       expectedContentLength: 0, textEncodingName: nil)
            return StubURLProtocol.StubResponse(response: response, data: Data())
        }
        let exp = expectation(description: "non-http response")
        makeStubbedClient().upload(makeBody()) { result in
            guard case .failure(DelayedEventsError.invalidResponse) = result else {
                return XCTFail("expected invalidResponse, got \(result)")
            }
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
    }
}

// MARK: - URLProtocol stub

/// Intercepts requests so `upload()`'s completion branches can be tested without a
/// live server. Tests run serially, so a static responder (reset in `tearDown`) is safe.
class StubURLProtocol: URLProtocol {
    struct StubResponse {
        let response: URLResponse?
        let data: Data?
        let error: Error?
        init(response: URLResponse? = nil, data: Data? = nil, error: Error? = nil) {
            self.response = response
            self.data = data
            self.error = error
        }
    }

    static var responder: ((URLRequest) -> StubResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = StubURLProtocol.responder else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let stub = responder(request)
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if let response = stub.response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        if let data = stub.data {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
