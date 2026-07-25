import Testing
import Foundation
@testable import Runner

struct RunnerWidgetsContractTests {
    @Test func extensionContractHasStableIdentifiers() {
        #expect(RunnerWidgetContract.bundleIdentifier == "com.farid.runner.widgets")
        #expect(RunnerWidgetContract.extensionPointIdentifier ==
                "com.apple.widgetkit-extension")
    }

    @Test func contentStateRoundTripsForTheExtensionBoundary() throws {
        let expected = RunAttributes.ContentState(snapshot: RunActivitySnapshot(
            status: .paused,
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            movingSeconds: 321,
            distanceMeters: 1_234,
            paceSecondsPerKm: 260,
            reducedAccuracy: false,
            message: nil
        ))
        let data = try JSONEncoder().encode(expected)
        let decoded = try JSONDecoder().decode(
            RunAttributes.ContentState.self,
            from: data
        )
        #expect(decoded == expected)
    }
}
