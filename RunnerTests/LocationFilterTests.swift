import Testing
import CoreLocation
@testable import Runner

struct LocationFilterTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func loc(x: Double, y: Double, t: TimeInterval, acc: Double = 5) -> CLLocation {
        let lat = 45.5 + y / 111_320.0
        let lon = -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180))
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                          altitude: 30, horizontalAccuracy: acc, verticalAccuracy: 10,
                          timestamp: base.addingTimeInterval(t))
    }

    @Test func firstSampleAccepted() {
        let d = LocationFilter.evaluate(candidate: loc(x: 0, y: 0, t: 0), lastKept: nil, now: base)
        #expect(d == LocationFilter.Decision(accepted: true, afterGap: false))
    }

    @Test func rejectsBadAccuracy() {
        let d = LocationFilter.evaluate(candidate: loc(x: 0, y: 0, t: 0, acc: 31), lastKept: nil, now: base)
        #expect(d.accepted == false)
        let invalid = LocationFilter.evaluate(candidate: loc(x: 0, y: 0, t: 0, acc: -1), lastKept: nil, now: base)
        #expect(invalid.accepted == false)
    }

    @Test func rejectsStaleSample() {
        let d = LocationFilter.evaluate(candidate: loc(x: 0, y: 0, t: 0),
                                        lastKept: nil, now: base.addingTimeInterval(11))
        #expect(d.accepted == false)
    }

    @Test func rejectsTinyDisplacement() {
        let last = loc(x: 0, y: 0, t: 0)
        let d = LocationFilter.evaluate(candidate: loc(x: 2, y: 0, t: 1), lastKept: last,
                                        now: base.addingTimeInterval(1))
        #expect(d.accepted == false)
    }

    @Test func acceptsNormalMovement() {
        let last = loc(x: 0, y: 0, t: 0)
        let d = LocationFilter.evaluate(candidate: loc(x: 10, y: 0, t: 5), lastKept: last,
                                        now: base.addingTimeInterval(5))
        #expect(d == LocationFilter.Decision(accepted: true, afterGap: false))
    }

    @Test func flagsGapAfterSignalLoss() {
        let last = loc(x: 0, y: 0, t: 0)
        let d = LocationFilter.evaluate(candidate: loc(x: 200, y: 0, t: 60), lastKept: last,
                                        now: base.addingTimeInterval(60))
        #expect(d == LocationFilter.Decision(accepted: true, afterGap: true))
    }
}
