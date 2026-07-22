import AmplitudeVideoAnalytics
import SwiftUI

@main
struct VideoDemoApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}

/// Root tab container hosting the SwiftUI and UIKit playback demo screens.
struct RootTabView: View {
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
        }
    }
}
