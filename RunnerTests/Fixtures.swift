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

/// A `UserDefaults` suite nobody else can see.
///
/// `AppModel` and `SyncCoordinator` both persist through an injected store, but
/// only `SyncCoordinator`'s tests used to isolate it — the five test files that
/// build `AppModel`s all shared `UserDefaults.standard`, in parallel, since
/// Swift Testing does not serialize suites. Every one of them is now given its
/// own suite through this.
func isolatedDefaults(_ label: String) -> UserDefaults {
    let name = "\(label)-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}
