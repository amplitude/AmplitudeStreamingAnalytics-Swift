import AmplitudeStreamingAnalytics
import SwiftUI

@main
struct StreamingDemoApp: App {
    @StateObject private var analytics = DemoAnalytics()

    init() {
        DemoAudioSession.configureForBackgroundPlayback()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(analytics)
        }
    }
}

/// Root tab container hosting the SwiftUI and UIKit playback demo screens plus the activity panel.
struct RootTabView: View {
    @EnvironmentObject private var analytics: DemoAnalytics

    var body: some View {
        TabView {
            SwiftUIPlayerScreen()
                .tabItem {
                    Label("SwiftUI", systemImage: "swift")
                }

            UIKitPlayerScreen()
                .tabItem {
                    Label("UIKit", systemImage: "uiwindow.split.2x1")
                }

            StreamActivityView(log: analytics.activity)
                .tabItem {
                    Label("Activity", systemImage: "waveform.path.ecg")
                }
        }
    }
}
