# Events

> **Alpha.** This SDK is ready to use in production, but nothing in it is final. The public API, the internal behaviour, and the events it sends can all change before GA.

> **Note:** Scope
>
> These pages describe the Alpha. They will be removed at GA, when [the Amplitude docsite](https://amplitude.com/docs) takes over.

**Package:** AmplitudeStreamingAnalytics
**Latest version:** unreleased; install by commit SHA

The SDK sends two events: `[Amplitude] Stream Started` and `[Amplitude] Stream Stopped`.

## Viewings and plays

A **viewing** runs from `trackPlayer(player:content:)` until your call to `stopTracking(player:)`,
the player deallocating, or the player reporting an error. It is identified by `stream_session_id`.
After an error the SDK no longer tracks that player; call `trackPlayer(player:content:)` again to
start a new viewing.

A viewing contains one or more **plays**. A play starts when the player starts playing, or at once
if it is already playing when you call `trackPlayer(player:content:)`. It ends when the player
pauses, reaches the end of the item or reports an error, when the player deallocates, or when you
call `stopTracking(player:)`. Seeking and buffering do not end a play. Playing again after the end
of the item starts a new play in the same viewing.

Each play has its own `play_id` and sends its own Started and Stopped pair. So a viewer who
pauses once and resumes produces two of each.

> **Note:** Count viewings with `stream_session_id`
>
> Counting `[Amplitude] Stream Started` events gives you plays. Every pause and resume adds one. Count distinct `stream_session_id` values to get viewings.

> **Note:** Do not add up `play_time`
>
> `play_time` is a running total for the whole viewing. It carries on counting across plays and never resets, so each Stopped event in a viewing repeats everything the earlier ones already reported. Summing it over a viewing's Stopped events counts the early plays several times.
>
> For a viewing's total, read `play_time` from its last Stopped event. For one play alone, subtract the previous Stopped event's value within the same `stream_session_id`.

## `[Amplitude] Stream Started`

Sent when a play starts. Unless the player is already playing, this is not the moment you call
`trackPlayer(player:content:)`; the SDK waits for playback to begin.

| Property | Type | Always present | Description |
| --- | --- | --- | --- |
| `content_id` | `String` | No | From `PlayerContent.contentId`. Omitted when you leave it `nil`. |
| `title` | `String` | No | From `PlayerContent.title`. Omitted when you leave it `nil`. |
| `media_type` | `String` | Yes | Always `"video"` in the Alpha. |
| `delivery_mode` | `String` | Yes | `"on_demand"` or `"live"`. From `PlayerContent.deliveryMode`. When you leave that `nil`, the SDK sends `"live"` if the item has no duration and `"on_demand"` if it has one, judged on each event from the duration known at that moment. |
| `stream_session_id` | `String` | Yes | Identifies the viewing. |
| `play_id` | `String` | Yes | Identifies the play within the viewing. |
| `duration` | `Double` | No | The item's length in seconds. Omitted for live streams and until the player reports one. |
| `start_time` | `Double` | Yes | Where this play started, as a playhead position in seconds. On a viewing's second play this is where the second play began. |
| `position` | `Double` | Yes | The playhead position in seconds when the event was sent. |

## `[Amplitude] Stream Stopped`

Sent when a play ends: a pause, the end of the item, an error, the player deallocating, or your
call to `stopTracking(player:)` while the player is playing. Seeking and buffering do not send it.
A viewing that ends while no play is open sends nothing: `stopTracking(player:)`, deallocation or
an error on a paused or finished player finds that play already closed.

A play that never closes reaches your data with `stop_reason` `timeout` instead. See the note below.

It carries every property `[Amplitude] Stream Started` carries, plus:

| Property | Type | Always present | Description |
| --- | --- | --- | --- |
| `play_time` | `Double` | Yes | Seconds the playhead has advanced while playing in this **viewing**, counting every play. Pauses, buffering and seeks add nothing; a section watched twice counts twice, so it can exceed `duration`. It counts content seconds, not clock time: at 2× speed a minute of viewing adds about 120. It never resets between plays, so this is a running total rather than the current play's figure. |
| `percent_completed` | `Double` | No | `position / duration` as a percentage, clamped to 0–100. Omitted when the duration is unknown. |
| `stop_reason` | `String` | Yes | One of `timeout`, `paused`, `ended`, `error`, `untracked`. `untracked` means you called `stopTracking(player:)` or the player deallocated. |
| `error_message` | `String` | No | Present only when the player reported an error message. |

Watch the scope difference between the two: `start_time` belongs to the current play, while
`play_time` covers the whole viewing.

> **Note:** `stop_reason` `timeout` marks a play that never closed
>
> `paused`, `ended`, `error` and `untracked` each say what stopped the play. `timeout` means the closing event never reached Amplitude: the app crashed or was force-quit, or the request carrying that event failed.
>
> While a play is open, the SDK keeps a stand-in Stopped event on the server and refreshes it at least once a minute. The server records it about an hour after the last refresh, with the `position` and `play_time` of that refresh. These rows mark the viewings that ended badly, so keep them.

## Known limitations

- `media_type` is always `"video"`. Audio-only playback has no separate event or value yet.
- A player tracked before its `AVPlayer.currentItem` is set never sends `stop_reason` `ended` or
  `error` for that item, and forward seeks in it are counted as play time. Track the player
  after you give it an item.
- `play_time` runs about half a second short per seek. The SDK reads the playhead once a second,
  and `AVPlayer` reports a seek only after the jump, so the playback since the last reading is not
  counted.
- A request that fails is not retried, so a Started or closing Stopped event in it is lost. A play
  whose closing event is lost this way still arrives, as `timeout`.
- The SDK does not follow `replaceCurrentItem`, so the next video's events carry the previous
  video's `content_id` and `title`. Stop and re-track instead. See
  [Getting started: Known limitations](getting-started.md#known-limitations).
