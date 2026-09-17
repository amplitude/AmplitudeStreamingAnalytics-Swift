# Events

> **Alpha.** This SDK is in Alpha. It is stable enough for production use, but its internal behaviour, its public API and the events it sends may all change before GA.

> **Note:** Scope of this document
>
> This describes the Alpha. It will be obsolete — and probably deleted — when the SDK reaches GA, at which point [the Amplitude docsite](https://amplitude.com/docs) becomes the source of truth.

**Package:** AmplitudeStreamingAnalytics
**Latest version:** unreleased — install by commit SHA

> **Note:** Wire taxonomy is frozen
>
> The event names and property keys on this page are frozen for Alpha. Renaming any of them would break existing charts and cohorts built on this data, even while other parts of this SDK may still change before GA.

Amplitude Streaming Analytics sends two event types: `[Amplitude] Stream Started` and
`[Amplitude] Stream Stopped`.

## Viewings and plays

One `trackPlayer(player:content:)` … `stopTracking(player:)` span is one **viewing**, identified
by `stream_session_id`. A viewing can contain more than one **play**: every time the player enters
the playing state while no play is already open, a new play starts; every time it leaves the
playing state — pausing, ending, erroring, or having its tracking stopped — that
play ends. A seek does not leave the playing state and does not end the play. Each play gets its
own `play_id` and its own `[Amplitude] Stream Started` /
`[Amplitude] Stream Stopped` pair.

> **Note:** Count viewings by `stream_session_id`, not by Started events
>
> A viewing that plays, pauses, and resumes sends `[Amplitude] Stream Started` more than once — once per play, not once per viewing. Counting `[Amplitude] Stream Started` events counts plays. To count viewings, count distinct `stream_session_id` values instead.

> **Note:** Do not sum `stream_duration` across a viewing's Stopped events
>
> The same trap on the other side. `stream_duration` is cumulative for the whole viewing: it keeps counting across the viewing's plays and is never reset when a new play starts, so every `[Amplitude] Stream Stopped` in a viewing carries the running total, not that play's share. `SUM(stream_duration)` over Stopped events therefore counts the earlier plays again on each later one. For a viewing's watch time, take its last `[Amplitude] Stream Stopped`; for one play's, take the difference between consecutive Stopped events within the `stream_session_id`.

## `[Amplitude] Stream Started`

Sent each time the player enters the playing state while no play is already open for that
viewing — not when `trackPlayer(player:content:)` is called.

| Property | Type | Always present | Description |
| --- | --- | --- | --- |
| `content_id` | `String` | No | From `PlayerContent.contentId`. Omitted when `nil`. |
| `title` | `String` | No | From `PlayerContent.title`. Omitted when `nil`. |
| `media_type` | `String` | Yes | Always `"video"` in this Alpha. |
| `delivery_mode` | `String` | Yes | `"on_demand"` or `"live"`. From `PlayerContent.deliveryMode`, or, when that is `nil`, inferred: `"live"` when the item has no duration, `"on_demand"` otherwise. |
| `stream_session_id` | `String` | Yes | Identifies this viewing. |
| `play_id` | `String` | Yes | Identifies the current play within the viewing. |
| `duration` | `Double` | No | The item's duration, in seconds. Omitted for a live stream, or before the player reports one. |
| `start_time` | `Double` | Yes | Play-scoped: the playhead position, in seconds, when **this play** started. On a viewing's second play this is where that play began, not where the viewing began. |
| `position` | `Double` | Yes | The playhead position, in seconds, at this event. |

## `[Amplitude] Stream Stopped`

Sent each time the player leaves the playing state while a play is open: pausing, ending,
erroring, or `stopTracking(player:)` ending the viewing mid-play. A seek does not leave the
playing state, so it does not send this. Calling
`stopTracking(player:)` while no play is open — for example, the player is already paused — sends
nothing, since there is no open play to close. A play that never closes produces one too, carrying
`stop_reason` `timeout` — see the note below. Carries every property
`[Amplitude] Stream Started` carries, plus:

| Property | Type | Always present | Description |
| --- | --- | --- | --- |
| `stream_duration` | `Double` | Yes | Viewing-scoped: seconds of playhead movement counted as watched, accumulated across **every play in the viewing** and never reset at a play boundary. This play's own share is the difference from the previous `[Amplitude] Stream Stopped` in the same `stream_session_id`. |
| `percent_completed` | `Double` | No | `position / duration`, as a percentage, clamped to 0–100. Omitted when `duration` is unknown. |
| `stop_reason` | `String` | No | One of `timeout`, `paused`, `ended`, `error`, `untracked`. |
| `error_message` | `String` | No | Present only when the player reported an error message. |

The two scopes sit side by side on one event: `start_time` describes this play, `stream_duration`
describes the viewing so far.

> **Note:** `stop_reason` `timeout` marks a play that never closed
>
> `paused`, `ended`, `error` and `untracked` each name something that ended the play. `timeout` means nothing did: the app stopped — a crash, a force-quit, or a lost network — before it could send a closing event for that play. The row still carries the `position` and `stream_duration` the play had reached before that happened. These rows mark exactly the viewings that ended badly, so do not discard them.

## Known limitations

- `media_type` is always `"video"`; there is no separate event type or value for audio-only
  playback yet.
- A player tracked before its `AVPlayer.currentItem` is set never sends `stop_reason` `ended` or
  `error` for that item, and a forward seek in it adds the skipped seconds to `stream_duration`.
  Track the player only after its item is set.
- A `replaceCurrentItem` is not followed: the viewing keeps reporting under the `PlayerContent` it
  started with, so the next item's events carry the previous item's `content_id` and `title`. Stop
  and re-track instead — see
  [Getting started: Known limitations](getting-started.md#known-limitations).
- The taxonomy above is frozen for Alpha — see the note near the top of this page.
