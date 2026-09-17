import XCTest

@testable import AmplitudeStreamingAnalytics

final class AmplitudeStreamingAnalyticsTests: XCTestCase {
    func testVersionsAreNonEmpty() {
        XCTAssertFalse(DelayedEventsInfo.version.isEmpty)
    }
}
