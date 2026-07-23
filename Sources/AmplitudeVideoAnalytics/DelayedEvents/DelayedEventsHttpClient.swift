import AmplitudeSwift
import Foundation

protocol DelayedEventsUploading: AnyObject {
    @discardableResult
    func upload(_ body: DelayedRequestBody, completion: @escaping (Result<Int, Error>) -> Void) -> URLSessionDataTask?
}

/// HTTP client for the delayed-events endpoint (`/2/httpapi/delayed`).
///
/// Structurally mirrors Amplitude-Swift's `HttpClient` (same session tuning, same
/// upload/`getRequest`/`getUrl` split, same `callbackQueue` marshaling and NSURLError
/// handling) so it reads as familiar to Amplitude reviewers. It deviates only where a
/// faithful copy would be wrong or impossible for a *guest* SDK built on public APIs:
///
///   1. It does NOT set `configuration.offline = true` on connection failure the way
///      `HttpClient` does. `configuration` here is the customer's shared Amplitude
///      instance config; mutating it would silently disable the customer's own
///      analytics uploads. We log and fail instead. (Respecting `offline` as a *read*
///      gate belongs in the pipeline layer, not here.)
///   2. No gzip. Amplitude-Swift compresses via `Data.gzipped()`, an internal extension
///      not available to us. We send uncompressed JSON.
///   3. Background-task handling uses our `BackgroundTaskRunner` rather than the internal
///      `VendorSystem.current.beginBackgroundTask()`.
///   4. No `Diagnostics`/`request_metadata` (internal to Amplitude-Swift).
///   5. Body is encoded from the typed `DelayedRequestBody` (delayed contract) rather
///      than hand-built like `HttpClient.getRequestData`.
final class DelayedEventsHttpClient: DelayedEventsUploading {
    let configuration: Configuration
    let session: URLSession
    let logger: (any Logger)?
    let callbackQueue: DispatchQueue

    init(configuration: Configuration, callbackQueue: DispatchQueue? = nil) {
        self.configuration = configuration
        self.logger = configuration.loggerProvider
        self.callbackQueue = callbackQueue ?? .global()

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.httpMaximumConnectionsPerHost = 2
        sessionConfiguration.urlCache = nil
        self.session = URLSession(configuration: sessionConfiguration, delegate: nil, delegateQueue: nil)
    }

    @discardableResult
    func upload(_ body: DelayedRequestBody, completion: @escaping (Result<Int, Error>) -> Void) -> URLSessionDataTask? {
        var sessionTask: URLSessionDataTask?
        let backgroundTaskCompletion = BackgroundTaskRunner.begin()
        do {
            let requestData = try JSONEncoder().encode(body)
            let request = try getRequest()
            sessionTask = session.uploadTask(with: request, from: requestData) { [callbackQueue, logger] data, response, error in
                callbackQueue.async {
                    if let error = error {
                        // Amplitude-Swift's HttpClient flips `configuration.offline = true`
                        // for these codes. We only log — see the type doc (deviation 1).
                        let nsError = error as NSError
                        if nsError.domain == NSURLErrorDomain {
                            switch nsError.code {
                            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                                 NSURLErrorCannotFindHost, NSURLErrorAppTransportSecurityRequiresSecureConnection,
                                 NSURLErrorNotConnectedToInternet, NSURLErrorBadURL:
                                logger?.error(message: "Delayed events connection failed: \(error.localizedDescription)")
                            default:
                                logger?.error(message: "Delayed events request failed: \(error.localizedDescription)")
                            }
                        } else {
                            logger?.error(message: "Delayed events request failed: \(error.localizedDescription)")
                        }
                        completion(.failure(error))
                    } else if let httpResponse = response as? HTTPURLResponse {
                        switch httpResponse.statusCode {
                        case 1..<300:
                            logger?.debug(message: "Delayed events request succeeded: HTTP \(httpResponse.statusCode)")
                            completion(.success(httpResponse.statusCode))
                        default:
                            let responseBody = String(data: data ?? Data(), encoding: .utf8) ?? ""
                            logger?.error(message: "Delayed events request failed: HTTP \(httpResponse.statusCode) \(responseBody)")
                            completion(.failure(DelayedEventsError.httpError(code: httpResponse.statusCode, data: data)))
                        }
                    } else {
                        logger?.error(message: "Delayed events request failed: non-HTTP response")
                        completion(.failure(DelayedEventsError.invalidResponse))
                    }
                    backgroundTaskCompletion?()
                }
            }
            sessionTask!.resume()
        } catch let error as DelayedEventsError {
            logger?.error(message: "Delayed events request failed: \(error)")
            completion(.failure(error))
            backgroundTaskCompletion?()
        } catch {
            logger?.error(message: "Delayed events request failed: body encoding error \(error)")
            completion(.failure(error))
            backgroundTaskCompletion?()
        }
        return sessionTask
    }

    func getUrl() -> String {
        if let url = configuration.serverUrl, !url.isEmpty {
            return url.hasSuffix("/") ? url + "delayed" : url + "/delayed"
        }
        return configuration.serverZone == .EU ? DelayedHosts.eu : DelayedHosts.us
    }

    func getRequest() throws -> URLRequest {
        let url = getUrl()

        let requestUrl: URL?
#if compiler(>=5.9)
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            requestUrl = URL(string: url, encodingInvalidCharacters: false)
        } else {
            requestUrl = URL(string: url)
        }
#else
        requestUrl = URL(string: url)
#endif

        guard let requestUrl else {
            throw DelayedEventsError.invalidUrl(url)
        }
        var request = URLRequest(url: requestUrl, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.addValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
