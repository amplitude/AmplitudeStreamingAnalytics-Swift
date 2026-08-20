import Foundation

/// How the delayed pipeline should handle an event.
///
/// Two cases, not three, because the wire has exactly two buckets: `events` (upserted under a
/// TTL) and `instant_events` (ingested now). "Finalize" is not a separate intent — it is
/// `.instant` for an `insert_id` that happens to have a live snapshot.
enum DelayConfig {
    /// Ingest now, via `instant_events`. If a snapshot already exists for this event's
    /// `insert_id`, this *is* its finalization: the snapshot is dropped in the same mutation.
    case instant

    /// Upsert the snapshot for this event's `insert_id` and extend its TTL, in seconds.
    case delayed(timeout: TimeInterval)
}
