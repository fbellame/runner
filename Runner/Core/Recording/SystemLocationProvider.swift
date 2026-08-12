import CoreLocation

@MainActor
final class SystemLocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    weak var delegate: LocationProvidingDelegate?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        // No distance filter: CoreLocation must keep delivering while he stands
        // still. With a 3 m filter, stopping stopped the callbacks, so the
        // auto-pause dwell had nothing to advance it and a stopped run simply
        // never paused. The route stays protected from the extra samples by
        // `LocationFilter.minDisplacementMeters`, which is a separate decision
        // from "is he moving" and stays at 3 m.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    var accuracyAuthorization: CLAccuracyAuthorization { manager.accuracyAuthorization }

    /// Test seam. A distance filter here silently starves `AutoPauseDetector`,
    /// which can only advance on delivered samples — the whole reason a stopped
    /// run failed to auto-pause in the field.
    var configuredDistanceFilter: CLLocationDistance { manager.distanceFilter }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func requestTemporaryFullAccuracy(purposeKey: String) {
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: purposeKey)
    }

    func startUpdates() {
        // Requires the "location" UIBackgroundModes entry (present since Task 1)
        // and an in-foreground start; keeps recording with the screen off.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stopUpdates() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    // MARK: CLLocationManagerDelegate (callbacks hop to MainActor)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.delegate?.didUpdate(locations: locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.delegate?.didChangeAuthorization(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.delegate?.didFail(error) }
    }
}
