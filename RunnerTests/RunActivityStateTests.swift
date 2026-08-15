import Testing
import Foundation
@testable import Runner

struct RunActivityStateTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func snapshot(status: RunActivityStatus,
                          seconds: Double = 0) -> RunActivitySnapshot {
        RunActivitySnapshot(
            status: status,
            startedAt: base,
            movingSeconds: seconds,
            distanceMeters: 0,
            paceSecondsPerKm: nil,
            reducedAccuracy: false,
            message: nil
        )
    }

    @Test func stateChangesUpdateImmediately() {
        #expect(RunActivityUpdatePolicy.shouldUpdate(
            previous: snapshot(status: .ready),
            next: snapshot(status: .recording),
            lastUpdateAt: base,
            now: base.addingTimeInterval(1)
        ))
    }

    @Test func statsAreThrottledUntilFiveSecondsHaveElapsed() {
        #expect(!RunActivityUpdatePolicy.shouldUpdate(
            previous: snapshot(status: .recording),
            next: snapshot(status: .recording, seconds: 4),
            lastUpdateAt: base,
            now: base.addingTimeInterval(4)
        ))
        #expect(RunActivityUpdatePolicy.shouldUpdate(
            previous: snapshot(status: .recording),
            next: snapshot(status: .recording, seconds: 5),
            lastUpdateAt: base,
            now: base.addingTimeInterval(5)
        ))
    }

    @Test func warningsUpdateImmediately() {
        let previous = snapshot(status: .recording)
        let next = RunActivitySnapshot(
            status: .recording,
            startedAt: base,
            movingSeconds: 1,
            distanceMeters: 0,
            paceSecondsPerKm: nil,
            reducedAccuracy: true,
            message: String(localized: "Precise Location is off")
        )
        #expect(RunActivityUpdatePolicy.shouldUpdate(
            previous: previous,
            next: next,
            lastUpdateAt: base,
            now: base.addingTimeInterval(1)
        ))
    }
}
