# Configuration

> **Alpha.** This SDK is in Alpha. It is stable enough for production use, but its internal behaviour, its public API and the events it sends may all change before GA.

> **Note:** Scope of this document
>
> This describes the Alpha. It will be obsolete — and probably deleted — when the SDK reaches GA, at which point [the Amplitude docsite](https://amplitude.com/docs) becomes the source of truth.

**Package:** AmplitudeStreamingAnalytics
**Latest version:** unreleased — install by commit SHA

`PlayerContent` describes the content you are tracking. Pass it to `trackPlayer(player:content:)`
when you start a viewing — see [Getting started](getting-started.md).

## PlayerContent

| Name | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `contentId` | `String?` | No | `nil` | Your identifier for the content. Sent as `content_id`. |
| `title` | `String?` | No | `nil` | Human-readable title. Sent as `title`. |
| `deliveryMode` | `DeliveryMode?` | No | `nil` | `.onDemand` or `.live`. When `nil`, inferred from whether the item has a duration. |
| `extraEventProperties` | `[String: Any]` | No | `[:]` | Extra properties merged into every event this viewing sends. |

```swift
let content = PlayerContent(
    contentId: "ep-42",
    title: "Pilot",
    deliveryMode: .onDemand,
    extraEventProperties: ["show_id": "show-7"]
)
```

### The collision rule

Every event starts from `extraEventProperties`, then the SDK sets its own properties on top. An
`extraEventProperties` entry under a key the SDK sets on that event is overwritten; one under a key
the SDK does not set on it survives. Which keys it sets depends on the event type — see
[Events](events.md) for what each one means.

| Key | On `[Amplitude] Stream Started` | On `[Amplitude] Stream Stopped` |
| --- | --- | --- |
| `media_type` | always | always |
| `delivery_mode` | always | always |
| `stream_session_id` | always | always |
| `play_id` | always | always |
| `start_time` | always | always |
| `position` | always | always |
| `content_id` | when `PlayerContent.contentId` is non-nil | same |
| `title` | when `PlayerContent.title` is non-nil | same |
| `duration` | when the item's duration is known — not a live stream, and the player has reported one | same |
| `stream_duration` | never set | always |
| `percent_completed` | never set | when the item's duration is known |
| `stop_reason` | never set | whenever the SDK has a reason for the stop, which it has for every Stopped event it sends |
| `error_message` | never set | only when the player reported an error message |

```swift
// contentId is nil, so it sets nothing: extraEventProperties["content_id"] survives as "x".
let content = PlayerContent(extraEventProperties: ["content_id": "x"])

// contentId is set, so it wins: the event carries "y", not "z".
let overridden = PlayerContent(contentId: "y", extraEventProperties: ["content_id": "z"])
```

Use `extraEventProperties` for keys that appear in neither column of the table. Relying on it to
override a conditional key only works while the SDK's own value for that key is absent, and it
never overrides the six keys the SDK always sets.

The four keys set on `[Amplitude] Stream Stopped` and never on `[Amplitude] Stream Started` are the
trap: an `extraEventProperties` entry named `stream_duration`, `percent_completed`, `stop_reason`
or `error_message` reaches every Started event intact, then is silently overwritten on the Stopped
events where the SDK has its own value — always for `stream_duration`, and on the conditions above
for the other three. One key, two meanings in the same viewing's data, and no error either way.
Pick a different name.

## What you cannot configure yet

`StreamingAnalyticsConfig` — the sample interval and the delayed-event TTL — is internal in Alpha.
There is no public initializer parameter or setter for either; both use SDK-chosen defaults.

## Known limitations

- Only `PlayerContent` is caller-configurable. Sampling interval and delayed-event TTL are fixed
  for Alpha.
