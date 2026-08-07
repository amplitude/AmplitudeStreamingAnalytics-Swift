import Foundation

/// Response from the delayed-events endpoint (`POST /2/httpapi/delayed`).
///
/// Per the backend contract (nova `DelayedEventServlet`):
///   - stored (`timeout > 0`): `{ "id", "expiration" }` where `expiration` is epoch **seconds**
///   - flushed immediately (`timeout == 0`): `{ "id", "flushed": true }`
///
/// A heartbeat/refresh pipeline correlates responses by `id` and can use `expiration`
/// to schedule the next pulse before the server-side TTL lapses.
struct DelayedResponseBody: Decodable, Equatable {
    let id: String
    let expiration: Int64?
    let flushed: Bool?
}
