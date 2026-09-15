import AmplitudeSwift
import Foundation

protocol DelayedEventsUploading: AnyObject {
    @discardableResult
    func upload(_ body: DelayedRequestBody,
                completion: @escaping (Result<DelayedResponseBody, Error>) -> Void) -> URLSessionDataTask?
}

final class DelayedEventsHttpClient: DelayedEventsUploading {
    private let configuration: Configuration
    private let session: URLSession
    private let logger: (any Logger)?

    init(configuration: Configuration,
         urlSessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        self.logger = configuration.loggerProvider
        // `.ephemeral`: no persistent cache/cookies/credentials; injectable for tests.
        self.session = URLSession(configuration: urlSessionConfiguration)
    }

    func getUrl() -> String {
        if let url = configuration.serverUrl, !url.isEmpty {
            return url.hasSuffix("/") ? url + "delayed" : url + "/delayed"
        }
        return configuration.serverZone == .EU ? DelayedHosts.eu : DelayedHosts.us
    }

    @discardableResult
    func upload(_ body: DelayedRequestBody,
                completion: @escaping (Result<DelayedResponseBody, Error>) -> Void) -> URLSessionDataTask? {
        let urlString = getUrl()
        guard let requestUrl = URL(string: urlString) else {
            logger?.error(message: "Delayed events request failed: id=\(body.id) invalid URL \(urlString)")
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
            logger?.error(message: "Delayed events request failed: id=\(body.id) body encoding error \(error)")
            completion(.failure(error))
            return nil
        }

        let task = session.uploadTask(with: request, from: data) { [logger, id = body.id] responseData, response, error in
            if let error {
                logger?.error(message: "Delayed events request failed: id=\(id) \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                logger?.error(message: "Delayed events request failed: id=\(id) non-HTTP response")
                completion(.failure(DelayedEventsError.invalidResponse))
                return
            }
            switch httpResponse.statusCode {
            case 1..<300:
                do {
                    let decoded = try JSONDecoder().decode(DelayedResponseBody.self, from: responseData ?? Data())
                    logger?.debug(message: "Delayed events request succeeded: id=\(id) HTTP \(httpResponse.statusCode)")
                    completion(.success(decoded))
                } catch {
                    logger?.error(message: "Delayed events request failed: id=\(id) HTTP \(httpResponse.statusCode) response decode error \(error)")
                    completion(.failure(error))
                }
            default:
                let bodyText = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                logger?.error(message: "Delayed events request failed: id=\(id) HTTP \(httpResponse.statusCode) \(bodyText)")
                completion(.failure(DelayedEventsError.httpError(code: httpResponse.statusCode, data: responseData)))
            }
        }
        task.resume()
        return task
    }
}
