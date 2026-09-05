import Foundation
import CoreLocation
@testable import Runner

// Shared test doubles.
//
// `FakeLocationProvider` lived inside `WorkoutRecorderTests.swift` while four
// other files depended on it, which made that one file load-bearing for the
// whole recording suite without saying so anywhere. `AnnouncementSpy` existed
// six times, byte-identical, in five files — two of them declaring it twice in
// the same file. Both now live here, next to `FakeHealthStore` and
// `FakeMotionActivityProvider`, which were already shared properly.

@MainActor
final class FakeLocationProvider: LocationProviding {
    weak var delegate: LocationProvidingDelegate?
    var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    var fullAccuracyRequests: [String] = []
    var started = false
    var stopped = false
    func requestWhenInUseAuthorization() {}
    func requestTemporaryFullAccuracy(purposeKey: String) { fullAccuracyRequests.append(purposeKey) }
    func startUpdates() { started = true }
    func stopUpdates() { stopped = true }
}

/// Captures what would have been spoken, in order.
@MainActor
final class AnnouncementSpy: Announcing {
    var events: [RunAnnouncement] = []
    func announce(_ event: RunAnnouncement) { events.append(event) }
}
