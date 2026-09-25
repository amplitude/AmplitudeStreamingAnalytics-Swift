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
| `contentId` | `String?` | No | `nil` | Your identifier for the content. Sent as `[Streaming] Content ID`. |
| `title` | `String?` | No | `nil` | Human-readable title. Sent as `[Streaming] Title`. |
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

| Key | On `[Streaming] Stream Started` | On `[Streaming] Stream Stopped` |
| --- | --- | --- |
| `[Streaming] Media Type` | always | always |
| `[Streaming] Delivery Mode` | always | always |
| `[Streaming] Stream Session ID` | always | always |
| `[Streaming] Play ID` | always | always |
| `[Streaming] Start Position Sec` | always | always |
| `[Streaming] Position Sec` | always | always |
| `[Streaming] Content ID` | when `PlayerContent.contentId` is set | same |
| `[Streaming] Title` | when `PlayerContent.title` is set | same |
| `[Streaming] Duration Sec` | when the player knows the item's duration | same |
| `[Streaming] Play Time Sec` | never | always |
| `[Streaming] Play Time Total Sec` | never | always |
| `[Streaming] Percent Completed` | never | when the player knows the item's duration |
| `[Streaming] Stop Reason` | never | always |
| `[Streaming] Error Message` | never | when the player reported an error message |

```swift
// contentId is nil, so the SDK sets nothing and your value survives as "x".
let content = PlayerContent(extraEventProperties: ["[Streaming] Content ID": "x"])

// contentId is set, so the event carries "y". The "z" is dropped.
let overridden = PlayerContent(contentId: "y", extraEventProperties: ["[Streaming] Content ID": "z"])
```

Pick names for `extraEventProperties` that the table does not list at all. Two cases go wrong
quietly:

- A conditional key such as `[Streaming] Content ID` lets your value through only while the SDK has no value
  of its own. The moment you set `contentId`, your property disappears from the data.
- The play-time keys, `[Streaming] Percent Completed`, `[Streaming] Stop Reason` and `[Streaming] Error Message` reach every Started
  event intact, because the SDK sets them only on Stopped events. The same key then means one
  thing on your Started events and another on your Stopped events, in the same viewing, with no
  error to tell you.
