# Events

> **Alpha.** This SDK is ready to use in production, but nothing in it is final. The public API, the internal behaviour, and the events it sends can all change before GA.

> **Note:** Scope
>
> These pages describe the Alpha. They will be removed at GA, when [the Amplitude docsite](https://amplitude.com/docs) takes over.

**Package:** AmplitudeStreamingAnalytics
**Latest version:** unreleased; install by commit SHA

The SDK sends two events: `[Streaming] Stream Started` and `[Streaming] Stream Stopped`.

## Viewings and plays

A **viewing** runs from `trackPlayer(player:content:)` until your call to `stopTracking(player:)`,
the player deallocating, or the player reporting an error. It is identified by `[Streaming] Stream Session ID`.
After an error the SDK no longer tracks that player; call `trackPlayer(player:content:)` again to
start a new viewing.

A viewing contains one or more **plays**. A play starts when the player starts playing, or at once
if it is already playing when you call `trackPlayer(player:content:)`. It ends when the player
pauses, reaches the end of the item or reports an error, when the player deallocates, or when you
call `stopTracking(player:)`. Seeking and buffering do not end a play. Playing again after the end
of the item starts a new play in the same viewing.

Each play has its own `[Streaming] Play ID` and sends its own Started and Stopped pair. So a viewer who
pauses once and resumes produces two of each.

> **Note:** Count viewings with `[Streaming] Stream Session ID`
>
> Counting `[Streaming] Stream Started` events gives you plays. Every pause and resume adds one. Count distinct `[Streaming] Stream Session ID` values to get viewings.

> **Note:** Two play-time properties, two ways to aggregate
>
> `[Streaming] Play Time Sec` covers one play and starts from zero on every play, so sum it over a viewing's Stopped events to get the viewing's total.
>
> `[Streaming] Play Time Total Sec` is that sum already: a running total for the whole viewing, repeated on every Stopped event. Do not add it up. Take the largest value per `[Streaming] Stream Session ID`, which is the one on the viewing's last Stopped event.

## `[Streaming] Stream Started`

Sent when a play starts. Unless the player is already playing, this is not the moment you call
`trackPlayer(player:content:)`; the SDK waits for playback to begin.

| Property | Type | Always present | Description |
| --- | --- | --- | --- |
| `[Streaming] Content ID` | `String` | No | From `PlayerContent.contentId`. Omitted when you leave it `nil`. |
| `[Streaming] Title` | `String` | No | From `PlayerContent.title`. Omitted when you leave it `nil`. |
| `[Streaming] Media Type` | `String` | Yes | Always `"video"` in the Alpha. |
| `[Streaming] Delivery Mode` | `String` | Yes | `"on_demand"` or `"live"`. From `PlayerContent.deliveryMode`. When you leave that `nil`, the SDK sends `"live"` if the item has no duration and `"on_demand"` if it has one, judged on each event from the duration known at that moment. |
| `[Streaming] Stream Session ID` | `String` | Yes | Identifies the viewing. |
| `[Streaming] Play ID` | `String` | Yes | Identifies the play within the viewing. |
| `[Streaming] Duration Sec` | `Double` | No | The item's length in seconds. Omitted for live streams and until the player reports one. |
| `[Streaming] Start Position Sec` | `Double` | Yes | Where this play started, as a playhead position in seconds. On a viewing's second play this is where the second play began. |
| `[Streaming] Position Sec` | `Double` | Yes | The playhead position in seconds when the event was sent. |

## `[Streaming] Stream Stopped`

Sent when a play ends: a pause, the end of the item, an error, the player deallocating, or your
call to `stopTracking(player:)` while the player is playing. Seeking and buffering do not send it.
A viewing that ends while no play is open sends nothing: `stopTracking(player:)`, deallocation or
an error on a paused or finished player finds that play already closed.

A play that never closes reaches your data with `[Streaming] Stop Reason` `timeout` instead. See the note below.

It carries every property `[Streaming] Stream Started` carries, plus:

| Property | Type | Always present | Description |
| --- | --- | --- | --- |
| `[Streaming] Play Time Sec` | `Double` | Yes | Seconds the playhead has advanced while playing in this **play**. Buffering and seeks add nothing; a section watched twice counts twice, so it can exceed `[Streaming] Duration Sec`. It counts content seconds, not clock time: at 2× speed a minute of viewing adds about 120. A pause ends the play, so the next play starts again from zero. |
| `[Streaming] Play Time Total Sec` | `Double` | Yes | The same measure for the whole **viewing**: every play's `[Streaming] Play Time Sec` so far, including this one. It never resets between plays. |
| `[Streaming] Percent Completed` | `Double` | No | `position / duration` as a percentage, clamped to 0–100. Omitted when the duration is unknown. |
| `[Streaming] Stop Reason` | `String` | Yes | One of `timeout`, `paused`, `ended`, `error`, `untracked`. `untracked` means you called `stopTracking(player:)` or the player deallocated. |
| `[Streaming] Error Message` | `String` | No | Present only when the player reported an error message. |

Watch the scope: `[Streaming] Start Position Sec` and `[Streaming] Play Time Sec` belong to the current play, while
`[Streaming] Play Time Total Sec` covers the whole viewing.

> **Note:** `[Streaming] Stop Reason` `timeout` marks a play that never closed
>
> `paused`, `ended`, `error` and `untracked` each say what stopped the play. `timeout` means the closing event never reached Amplitude: the app crashed or was force-quit, or the request carrying that event failed.
>
> While a play is open, the SDK keeps a stand-in Stopped event on the server and refreshes it at least once a minute. The server records it about an hour after the last refresh, with the position and play time of that refresh. These rows mark the viewings that ended badly, so keep them.

## Known limitations

- `[Streaming] Media Type` is always `"video"`. Audio-only playback has no separate event or value yet.
- A player tracked before its `AVPlayer.currentItem` is set never sends `[Streaming] Stop Reason` `ended` or
  `error` for that item, and forward seeks in it are counted as play time. Track the player
  after you give it an item.
- Play time runs about half a second short per seek. The SDK reads the playhead once a second,
  and `AVPlayer` reports a seek only after the jump, so the playback since the last reading is not
  counted.
- A request that fails is not retried, so a Started or closing Stopped event in it is lost. A play
  whose closing event is lost this way still arrives, as `timeout`.
- The SDK does not follow `replaceCurrentItem`, so the next video's events carry the previous
  video's `[Streaming] Content ID` and `[Streaming] Title`. Stop and re-track instead. See
  [Getting started: Known limitations](getting-started.md#known-limitations).
