// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AmplitudeStreamingAnalytics-Swift",
    platforms: [.iOS("13.0"), .tvOS("13.0"), .macOS("10.15")],
    products: [
        // Single target/module: CocoaPods distribution is planned (one pod = one module).
        // DelayedEvents/ stays extractable via the CI-guarded directory boundary.
        .library(name: "AmplitudeStreamingAnalytics", targets: ["AmplitudeStreamingAnalytics"])
    ],
    dependencies: [
        .package(url: "https://github.com/amplitude/Amplitude-Swift.git", from: "1.18.6"),
    ],
    targets: [
        .target(
            name: "AmplitudeStreamingAnalytics",
            dependencies: [.product(name: "AmplitudeSwift", package: "Amplitude-Swift")],
            path: "Sources/AmplitudeStreamingAnalytics"
        ),
        .testTarget(
            name: "AmplitudeStreamingAnalyticsTests",
            dependencies: [.target(name: "AmplitudeStreamingAnalytics")],
            path: "Tests/AmplitudeStreamingAnalyticsTests"
        ),
    ]
)
