import Testing
import Foundation
@testable import Runner

struct SmokeTests {
    @Test func testsRunAgainstTheAppHost() {
        // Bundle.main is Runner.app only when TEST_HOST wiring is correct —
        // this catches broken test-target configuration, not app logic.
        #expect(Bundle.main.bundleIdentifier == "com.farid.runner")
    }
}
