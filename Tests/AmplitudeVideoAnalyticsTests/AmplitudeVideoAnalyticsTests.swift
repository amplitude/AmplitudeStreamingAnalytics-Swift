import XCTest

@testable import AmplitudeVideoAnalytics

final class AmplitudeVideoAnalyticsTests: XCTestCase {
    func testVersionsAreNonEmpty() {
        XCTAssertFalse(AmplitudeVideoAnalyticsInfo.version.isEmpty)
        XCTAssertFalse(DelayedEventsInfo.version.isEmpty)
    }
}
