import XCTest

// THROWAWAY: a warning in a test target, to prove swift-warnings.sh counts it.
final class ThrowawayWarningTests: XCTestCase {
    func testThrowawayWarning() {
        let unused = 1
    }
}
