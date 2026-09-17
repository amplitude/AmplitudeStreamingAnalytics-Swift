import SwiftUI

// Debug tab: a live list of the `[Amplitude] Stream *` events the plugin has emitted this run,
// with a capture toggle. Request-level inspection is deferred to the Kong cross-SDK harness.
struct StreamActivityView: View {
    @EnvironmentObject private var analytics: DemoAnalytics
    @ObservedObject private var log: StreamActivityLog

    init(log: StreamActivityLog) {
        _log = ObservedObject(wrappedValue: log)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Capture tracking", isOn: $log.isCapturing)
                }

                if log.entries.isEmpty {
                    Section {
                        Text("No stream events yet. Play a video in the SwiftUI or UIKit tab.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Events") {
                        ForEach(log.entries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.eventType).font(.subheadline).bold()
                                Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                                Text(entry.at, style: .time).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Activity")
            .toolbar {
                Button("Clear", action: log.clear).disabled(log.entries.isEmpty)
            }
        }
    }
}
