import Foundation

/// How long the server should hold an event before ingesting it.
///
/// `timeout` is in **seconds**:
///   - `nil` — not delayed; the event rides along as an instant event and is ingested now
///   - `0` — finalize: flush the stored snapshot for this `insert_id` immediately
///   - `> 0` — upsert: replace the stored snapshot and extend its TTL
///
/// `id` is reserved for a future per-event delay id. v1 keys everything off a single
/// pipeline-level delay id, so a non-nil value here is carried but not acted on.
struct DelayConfig {
    let id: String?
    let timeout: TimeInterval?

    init(id: String? = nil, timeout: TimeInterval?) {
        self.id = id
        self.timeout = timeout
    }
}
