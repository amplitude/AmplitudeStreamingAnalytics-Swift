import Foundation

/// Every knob of the delayed transport in one value, injected as a unit down the chain.
/// `pulseInterval` is how often the live set is re-sent to keep the server row alive;
/// `ttlMs` is how long the server keeps that row before ingesting it on its own.
struct DelayedEventsConfiguration {
    var pulseInterval: TimeInterval = 60
    var ttlMs: Int64 = 3_600_000
    var eventsSizeLimit = 40_000
}
