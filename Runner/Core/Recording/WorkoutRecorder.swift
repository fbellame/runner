import Foundation
import CoreLocation
import Observation

struct RecordedWorkout: Equatable, Sendable {
    let type: ActivityType
    let start: Date
    let end: Date
    let movingSeconds: Double
    let distanceMeters: Double
    let route: [RoutePoint]
    let splitSeconds: [Double]
}

@MainActor
@Observable
final class WorkoutRecorder: LocationProvidingDelegate {
    enum State: Equatable { case idle, recording, autoPaused, manuallyPaused }

    private(set) var state: State = .idle
    private(set) var activity: ActivityType = .run
    private(set) var startedAt: Date?
    private(set) var movingSeconds: Double = 0
    private(set) var distanceMeters: Double = 0
    private(set) var route: [RoutePoint] = []
    private(set) var splitSeconds: [Double] = []
    private(set) var authorizationDenied = false

    var livePoints: Int { PointsEngine.livePoints(type: activity, distanceMeters: distanceMeters) }
    var paceSecondsPerKm: Double? {
        guard distanceMeters >= 100 else { return nil }
        return movingSeconds / (distanceMeters / 1000.0)
    }
    var onKmSplit: ((Int) -> Void)?

    private let provider: LocationProviding
    private let checkpoints: CheckpointStore
    private let checkpointInterval: TimeInterval
    private var lastKeptLocation: CLLocation?
    private var autoPause: AutoPauseDetector?
    private var lastCheckpointAt: Date?
    private var lastSplitMovingSeconds: Double = 0

    init(provider: LocationProviding,
         checkpoints: CheckpointStore = CheckpointStore(),
         checkpointInterval: TimeInterval = 30) {
        self.provider = provider
        self.checkpoints = checkpoints
        self.checkpointInterval = checkpointInterval
        provider.delegate = self
    }

    func requestPermission() {
        provider.requestWhenInUseAuthorization()
    }

    func start(activity: ActivityType, resumeFrom checkpoint: SessionCheckpoint? = nil) {
        self.activity = activity
        if let checkpoint {
            startedAt = checkpoint.startedAt
            movingSeconds = checkpoint.movingSeconds
            distanceMeters = checkpoint.distanceMeters
            route = checkpoint.route
            splitSeconds = checkpoint.splitSeconds
            lastSplitMovingSeconds = checkpoint.splitSeconds.reduce(0, +)
        } else {
            startedAt = Date()
            movingSeconds = 0
            distanceMeters = 0
            route = []
            splitSeconds = []
            lastSplitMovingSeconds = 0
        }
        lastKeptLocation = nil
        lastCheckpointAt = nil
        autoPause = AutoPauseDetector(activity: activity)
        state = .recording
        provider.startUpdates()
    }

    func pauseManually() {
        guard state == .recording || state == .autoPaused else { return }
        state = .manuallyPaused
        saveCheckpoint(at: Date())
    }

    func resumeManually() {
        guard state == .manuallyPaused else { return }
        autoPause = AutoPauseDetector(activity: activity)
        lastKeptLocation = nil // fresh segment; gap marker will show honestly
        state = .recording
    }

    func finish() -> RecordedWorkout {
        provider.stopUpdates()
        let workout = RecordedWorkout(type: activity,
                                      start: startedAt ?? Date(),
                                      end: Date(),
                                      movingSeconds: movingSeconds,
                                      distanceMeters: distanceMeters,
                                      route: route,
                                      splitSeconds: splitSeconds)
        checkpoints.clear()
        reset()
        return workout
    }

    func discard() {
        provider.stopUpdates()
        checkpoints.clear()
        reset()
    }

    private func reset() {
        state = .idle
        startedAt = nil
        movingSeconds = 0
        distanceMeters = 0
        route = []
        splitSeconds = []
        lastKeptLocation = nil
        lastCheckpointAt = nil
        autoPause = nil
        lastSplitMovingSeconds = 0
    }

    // MARK: LocationProvidingDelegate

    func didUpdate(locations: [CLLocation]) {
        for location in locations { ingest(location) }
    }

    func didChangeAuthorization(_ status: CLAuthorizationStatus) {
        authorizationDenied = (status == .denied || status == .restricted)
    }

    func didFail(_ error: Error) {
        // GPS hiccups: keep the session alive; the gap logic handles the hole.
    }

    // MARK: Core ingestion

    private func ingest(_ location: CLLocation) {
        guard state == .recording || state == .autoPaused else { return }

        // 1. Speed for auto-pause: sensor speed, else computed from last kept point.
        let sensorSpeed = location.speed
        let computedSpeed: Double
        if let last = lastKeptLocation {
            let dt = location.timestamp.timeIntervalSince(last.timestamp)
            computedSpeed = dt > 0 ? location.distance(from: last) / dt : 0
        } else {
            computedSpeed = 0
        }
        let speed = sensorSpeed >= 0 ? sensorSpeed : computedSpeed

        // 2. Feed the detector on EVERY sample so standing still triggers a pause.
        if var detector = autoPause {
            let paused = detector.update(speed: speed, at: location.timestamp)
            autoPause = detector
            state = paused ? .autoPaused : .recording
        }

        // 3. Accept or reject the sample.
        let decision = LocationFilter.evaluate(candidate: location,
                                               lastKept: lastKeptLocation,
                                               now: Date())
        guard decision.accepted, state == .recording else { return }

        // 4. Credit moving time (capped) and distance (not across gaps).
        if let last = lastKeptLocation {
            let dt = min(location.timestamp.timeIntervalSince(last.timestamp),
                         LocationFilter.maxSampleAge)
            if dt > 0 { movingSeconds += dt }
            if !decision.afterGap {
                distanceMeters += location.distance(from: last)
            }
        }
        route.append(RoutePoint(lat: location.coordinate.latitude,
                                lon: location.coordinate.longitude,
                                t: location.timestamp,
                                afterGap: decision.afterGap))
        lastKeptLocation = location

        // 5. Km splits.
        let completedKm = Int(distanceMeters / 1000.0)
        while splitSeconds.count < completedKm {
            splitSeconds.append(movingSeconds - lastSplitMovingSeconds)
            lastSplitMovingSeconds = movingSeconds
            onKmSplit?(splitSeconds.count)
        }

        // 6. Periodic checkpoint.
        if lastCheckpointAt == nil ||
            location.timestamp.timeIntervalSince(lastCheckpointAt!) >= checkpointInterval {
            saveCheckpoint(at: location.timestamp)
        }
    }

    private func saveCheckpoint(at time: Date) {
        guard let startedAt else { return }
        let checkpoint = SessionCheckpoint(activity: activity, startedAt: startedAt,
                                           movingSeconds: movingSeconds,
                                           distanceMeters: distanceMeters,
                                           route: route, splitSeconds: splitSeconds,
                                           savedAt: time)
        try? checkpoints.save(checkpoint)
        lastCheckpointAt = time
    }
}
