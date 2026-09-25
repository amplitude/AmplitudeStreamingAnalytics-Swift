# Configuration

> **Alpha.** This SDK is ready to use in production, but nothing in it is final. The public API, the internal behaviour, and the events it sends can all change before GA.

> **Note:** Scope
>
> These pages describe the Alpha. They will be removed at GA, when [the Amplitude docsite](https://amplitude.com/docs) takes over.

**Package:** AmplitudeStreamingAnalytics
**Latest version:** unreleased; install by commit SHA

`PlayerContent` describes the content you are tracking. Pass it to `trackPlayer(player:content:)`
when you start a viewing. See [Getting started](getting-started.md).

## PlayerContent

| Name | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `contentId` | `String?` | No | `nil` | Your identifier for the content. Sent as `content_id`. |
| `title` | `String?` | No | `nil` | Human-readable title. Sent as `title`. |
| `deliveryMode` | `DeliveryMode?` | No | `nil` | `.onDemand` or `.live`. When `nil`, the SDK infers it from whether the item has a duration. |
| `extraEventProperties` | `[String: Any]` | No | `[:]` | Extra properties added to every event this viewing sends. |

```swift
let content = PlayerContent(
    contentId: "ep-42",
    title: "Pilot",
    deliveryMode: .onDemand,
    extraEventProperties: ["show_id": "show-7"]
)
```

## How extraEventProperties merges

The SDK starts each event from your `extraEventProperties`, then writes its own properties over
the top. If you use a key the SDK also sets on that event, the SDK's value wins and yours is gone.
If you use a key the SDK does not set on that event, your value goes through.

Which keys the SDK sets depends on the event. See [Events](events.md) for what each one means.

| Key | On `[Amplitude] Stream Started` | On `[Amplitude] Stream Stopped` |
| --- | --- | --- |
| `media_type` | always | always |
| `delivery_mode` | always | always |
| `stream_session_id` | always | always |
| `play_id` | always | always |
| `start_time` | always | always |
| `position` | always | always |
| `content_id` | when `PlayerContent.contentId` is set | same |
| `title` | when `PlayerContent.title` is set | same |
| `duration` | when the player knows the item's duration | same |
| `play_time` | never | always |
| `percent_completed` | never | when the player knows the item's duration |
| `stop_reason` | never | always |
| `error_message` | never | when the player reported an error message |

```swift
// contentId is nil, so the SDK sets nothing and your value survives as "x".
let content = PlayerContent(extraEventProperties: ["content_id": "x"])

// contentId is set, so the event carries "y". The "z" is dropped.
let overridden = PlayerContent(contentId: "y", extraEventProperties: ["content_id": "z"])
```

Pick names for `extraEventProperties` that the table does not list at all. Two cases go wrong
quietly:

- A conditional key such as `content_id` lets your value through only while the SDK has no value
  of its own. The moment you set `contentId`, your property disappears from the data.
- `play_time`, `percent_completed`, `stop_reason` and `error_message` reach every Started
  event intact, because the SDK sets them only on Stopped events. The same key then means one
  thing on your Started events and another on your Stopped events, in the same viewing, with no
  error to tell you.
