import Foundation

/// How the delayed pipeline should handle an event.
enum DelayConfig {
    /// Ingest now, via `instant_events`. For an `insert_id` that has a live snapshot, this *is*
    /// its finalization — the snapshot is dropped in the same mutation.
    case instant

    /// Upsert the snapshot for this event's `insert_id` and extend its TTL, in seconds.
    case delayed(timeout: TimeInterval)
}
