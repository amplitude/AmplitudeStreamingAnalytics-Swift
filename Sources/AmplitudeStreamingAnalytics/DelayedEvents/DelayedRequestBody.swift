import AmplitudeSwift
import Foundation

struct DelayedRequestBody: Codable {
    let apiKey: String
    let id: String
    /// How long the server keeps this row before ingesting it on its own. Zero means "ingest and
    /// delete it now". Named `timeout` on the wire, which reads like a request timeout it is not.
    let ttlMs: Int64
    let events: [BaseEvent]
    let instantEvents: [BaseEvent]?

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case id
        case ttlMs = "timeout"
        case events
        case instantEvents = "instant_events"
    }
}
