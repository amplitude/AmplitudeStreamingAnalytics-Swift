import AmplitudeSwift
import Foundation

protocol DelayedEventsUploading: AnyObject {
    @discardableResult
    func upload(_ body: DelayedRequestBody, completion: @escaping (Result<Int, Error>) -> Void) -> URLSessionDataTask?
}

final class DelayedEventsHttpClient: DelayedEventsUploading {
    private let configuration: Configuration
    private let session: URLSession
    private let logger: (any Logger)?

    init(configuration: Configuration) {
        self.configuration = configuration
        self.logger = configuration.loggerProvider
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.httpMaximumConnectionsPerHost = 2
        sessionConfiguration.urlCache = nil
        self.session = URLSession(configuration: sessionConfiguration)
    }

    func getUrl() -> String {
        if let url = configuration.serverUrl, !url.isEmpty {
            return url.hasSuffix("/") ? url + "delayed" : url + "/delayed"
        }
        return configuration.serverZone == .EU ? DelayedHosts.eu : DelayedHosts.us
    }

    @discardableResult
    func upload(_ body: DelayedRequestBody, completion: @escaping (Result<Int, Error>) -> Void) -> URLSessionDataTask? {
        let urlString = getUrl()
        guard let requestUrl = URL(string: urlString) else {
            logger?.error(message: "Delayed events request failed: invalid URL \(urlString)")
            completion(.failure(DelayedEventsError.invalidUrl(urlString)))
            return nil
        }

        var request = URLRequest(url: requestUrl, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.addValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            logger?.error(message: "Delayed events request failed: body encoding error \(error)")
            completion(.failure(error))
            return nil
        }

        let endBackgroundTask = BackgroundTaskRunner.begin()
        let task = session.uploadTask(with: request, from: data) { [logger] responseData, response, error in
            defer { endBackgroundTask?() }
            if let error {
                logger?.error(message: "Delayed events request failed: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                logger?.error(message: "Delayed events request failed: non-HTTP response")
                completion(.failure(DelayedEventsError.invalidResponse))
                return
            }
            switch httpResponse.statusCode {
            case 1..<300:
                logger?.debug(message: "Delayed events request succeeded: HTTP \(httpResponse.statusCode)")
                completion(.success(httpResponse.statusCode))
            default:
                let bodyText = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                logger?.error(message: "Delayed events request failed: HTTP \(httpResponse.statusCode) \(bodyText)")
                completion(.failure(DelayedEventsError.httpError(code: httpResponse.statusCode, data: responseData)))
            }
        }
        task.resume()
        return task
    }
}
