# Events

> **Alpha.** This SDK is ready to use in production, but nothing in it is final. The public API, the internal behaviour, and the events it sends can all change before GA.

> **Note:** Scope
>
> These pages describe the Alpha. They will be removed at GA, when [the Amplitude docsite](https://amplitude.com/docs) takes over.

**Package:** AmplitudeStreamingAnalytics
**Latest version:** unreleased; install by commit SHA

> **Note:** These names are frozen
>
> The event names and property keys on this page will not change, even though other parts of the SDK still can. Renaming them would break charts and cohorts you have already built.

The SDK sends two events: `[Amplitude] Stream Started` and `[Amplitude] Stream Stopped`.

## Viewings and plays

Everything between `trackPlayer(player:content:)` and `stopTracking(player:)` is one **viewing**,
identified by `stream_session_id`.

A viewing contains one or more **plays**. A play starts when the player starts playing and ends
when it stops playing, whether that is a pause, the end of the item, an error, or your call to
`stopTracking(player:)`. Seeking does not stop playback, so it does not end a play.

Each play has its own `play_id` and sends its own Started and Stopped pair. So a viewer who
pauses once and resumes produces two of each.

> **Note:** Count viewings with `stream_session_id`
>
> Counting `[Amplitude] Stream Started` events gives you plays. Every pause and resume adds one. Count distinct `stream_session_id` values to get viewings.

> **Note:** Do not add up `stream_duration`
>
> `stream_duration` is a running total for the whole viewing. It carries on counting across plays and never resets, so each Stopped event in a viewing repeats everything the earlier ones already reported. Summing it over a viewing's Stopped events counts the early plays several times.
>
> For a viewing's watch time, read `stream_duration` from its last Stopped event. For one play's watch time, subtract the previous Stopped event's value within the same `stream_session_id`.

## `[Amplitude] Stream Started`

Sent when the player starts playing. This is not the moment you call
`trackPlayer(player:content:)`; the SDK waits for playback to begin.

| Property | Type | Always present | Description |
| --- | --- | --- | --- |
| `content_id` | `String` | No | From `PlayerContent.contentId`. Omitted when you leave it `nil`. |
| `title` | `String` | No | From `PlayerContent.title`. Omitted when you leave it `nil`. |
| `media_type` | `String` | Yes | Always `"video"` in the Alpha. |
| `delivery_mode` | `String` | Yes | `"on_demand"` or `"live"`. From `PlayerContent.deliveryMode`. When you leave that `nil`, the SDK sends `"live"` if the item has no duration and `"on_demand"` if it has one. |
| `stream_session_id` | `String` | Yes | Identifies the viewing. |
| `play_id` | `String` | Yes | Identifies the play within the viewing. |
| `duration` | `Double` | No | The item's length in seconds. Omitted for live streams and until the player reports one. |
| `start_time` | `Double` | Yes | Where this play started, as a playhead position in seconds. On a viewing's second play this is where the second play began. |
| `position` | `Double` | Yes | The playhead position in seconds when the event was sent. |

## `[Amplitude] Stream Stopped`

Sent when the player stops playing: a pause, the end of the item, an error, or your call to
`stopTracking(player:)` while the player is playing. Seeking does not send it. Calling
`stopTracking(player:)` on a player that is already paused sends nothing, because the pause
already closed that play.

A play that never closes reaches your data with `stop_reason` `timeout` instead. See the note below.

It carries every property `[Amplitude] Stream Started` carries, plus:

| Property | Type | Always present | Description |
| --- | --- | --- | --- |
| `stream_duration` | `Double` | Yes | Seconds watched so far in this **viewing**, counting every play. It never resets between plays, so this is a running total rather than the current play's figure. |
| `percent_completed` | `Double` | No | `position / duration` as a percentage, clamped to 0–100. Omitted when the duration is unknown. |
| `stop_reason` | `String` | Yes | One of `timeout`, `paused`, `ended`, `error`, `untracked`. |
| `error_message` | `String` | No | Present only when the player reported an error message. |

Watch the scope difference between the two: `start_time` belongs to the current play, while
`stream_duration` covers the whole viewing.

> **Note:** `stop_reason` `timeout` marks a play that never closed
>
> `paused`, `ended`, `error` and `untracked` each say what stopped the play. A `timeout` reaches your data when no closing event ever arrived, because the app crashed, was force-quit, or lost the network first. The event still reports the `position` and `stream_duration` the play had reached. These rows mark the viewings that ended badly, so keep them.

## Known limitations

- `media_type` is always `"video"`. Audio-only playback has no separate event or value yet.
- A player tracked before its `AVPlayer.currentItem` is set never sends `stop_reason` `ended` or
  `error` for that item, and forward seeks in it are counted as watched time. Track the player
  after you give it an item.
- The SDK does not follow `replaceCurrentItem`, so the next video's events carry the previous
  video's `content_id` and `title`. Stop and re-track instead. See
  [Getting started: Known limitations](getting-started.md#known-limitations).
