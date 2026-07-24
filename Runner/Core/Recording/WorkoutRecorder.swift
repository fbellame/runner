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
    /// Part of the distance came from Health rather than this session's GPS.
    let distanceEstimated: Bool
    /// The walk detector opened this session; no one tapped Start.
    let autoStarted: Bool

    init(type: ActivityType, start: Date, end: Date, movingSeconds: Double,
         distanceMeters: Double, route: [RoutePoint], splitSeconds: [Double],
         distanceEstimated: Bool = false, autoStarted: Bool = false) {
        self.type = type
        self.start = start
        self.end = end
        self.movingSeconds = movingSeconds
        self.distanceMeters = distanceMeters
        self.route = route
        self.splitSeconds = splitSeconds
        self.distanceEstimated = distanceEstimated
        self.autoStarted = autoStarted
    }

    var paceSecondsPerKm: Double? {
        Self.pace(movingSeconds: movingSeconds, distanceMeters: distanceMeters)
    }

    /// nil under 100 m — too little signal for a meaningful pace.
    static func pace(movingSeconds: Double, distanceMeters: Double) -> Double? {
        guard distanceMeters >= 100 else { return nil }
        return movingSeconds / (distanceMeters / 1000.0)
    }
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
    private(set) var reducedAccuracy = false
    /// Opened by the walk detector rather than by a tap. Carried onto the workout.
    private(set) var autoStarted = false
    /// When backdated, the instant GPS actually began — the window before it has
    /// duration but no route, and its distance must come from Health.
    private(set) var gpsBeganAt: Date?
    /// True only until the first armed auto-pause-to-recording transition.
    /// This is the one-shot guard that prevents later auto-pause cycles from
    /// rebasing `startedAt`.
    private(set) var isArmed = false
    /// The timestamp of the last accepted recording sample — the true end of
    /// activity, distinct from whenever `finish` happens to be called.
    private(set) var lastMovingAt: Date?

    /// Must match a key in Info.plist's NSLocationTemporaryUsageDescriptionDictionary.
    static let fullAccuracyPurposeKey = "PreciseWorkout"

    var livePoints: Int { PointsEngine.livePoints(type: activity, distanceMeters: distanceMeters) }
    var paceSecondsPerKm: Double? {
        RecordedWorkout.pace(movingSeconds: movingSeconds, distanceMeters: distanceMeters)
    }
    var onKmSplit: ((Int) -> Void)?

    private let provider: LocationProviding
    private let checkpoints: CheckpointStore
    private let checkpointInterval: TimeInterval
    private let armedTimeout: Duration
    private let clock: () -> Date
    private var lastKeptLocation: CLLocation?
    private var autoPause: AutoPauseDetector?
    private var lastCheckpointAt: Date?
    private var lastSplitMovingSeconds: Double = 0
    private var timeAnchor: Date?
    private var pendingGap = false
    private var armedTimeoutTask: Task<Void, Never>?

    init(provider: LocationProviding,
         checkpoints: CheckpointStore = CheckpointStore(),
         checkpointInterval: TimeInterval = 30,
         armedTimeout: Duration = .seconds(600),
         clock: @escaping () -> Date = { Date() }) {
        self.provider = provider
        self.checkpoints = checkpoints
        self.checkpointInterval = checkpointInterval
        self.armedTimeout = armedTimeout
        self.clock = clock
        provider.delegate = self
    }

    func requestPermission() {
        provider.requestWhenInUseAuthorization()
    }

    /// `backdatedTo` starts the workout when the activity really began — before the
    /// app noticed and before GPS was running. The elapsed interval is credited as
    /// moving time up front, so duration is honest from the very first sample.
    func start(activity: ActivityType, resumeFrom checkpoint: SessionCheckpoint? = nil,
               backdatedTo walkBeganAt: Date? = nil, autoStarted: Bool = false,
               armed: Bool = false) {
        self.activity = activity
        self.autoStarted = autoStarted
        self.isArmed = armed && checkpoint == nil && walkBeganAt == nil
        let now = clock()
        gpsBeganAt = walkBeganAt == nil ? nil : now
        if let checkpoint {
            startedAt = checkpoint.startedAt
            movingSeconds = checkpoint.movingSeconds
            distanceMeters = checkpoint.distanceMeters
            route = checkpoint.route
            splitSeconds = checkpoint.splitSeconds
            lastSplitMovingSeconds = checkpoint.splitSeconds.reduce(0, +)
            pendingGap = !checkpoint.route.isEmpty // relaunch point must not join old route
        } else {
            startedAt = walkBeganAt ?? now
            movingSeconds = walkBeganAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
            distanceMeters = 0
            route = []
            splitSeconds = []
            lastSplitMovingSeconds = movingSeconds
            pendingGap = false
        }
        lastMovingAt = checkpoint?.route.last?.t
        lastKeptLocation = nil
        lastCheckpointAt = nil
        autoPause = AutoPauseDetector(activity: activity, startPaused: self.isArmed)
        timeAnchor = clock()
        state = self.isArmed ? .autoPaused : .recording
        // Approximate location (~km accuracy) fails the filter's 30 m gate, so the
        // session would silently record nothing: ask for precise, and flag the UI.
        reducedAccuracy = provider.accuracyAuthorization == .reducedAccuracy
        if reducedAccuracy {
            provider.requestTemporaryFullAccuracy(purposeKey: Self.fullAccuracyPurposeKey)
        }
        provider.startUpdates()
        // A new session must never inherit a previous one's pending timeout —
        // cancel unconditionally before deciding whether to arm a fresh one.
        armedTimeoutTask?.cancel()
        if isArmed {
            let timeout = armedTimeout
            armedTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                // Re-check after the suspension: isArmed may have changed while
                // asleep (movement started, or the session was finished/discarded/reset).
                guard !Task.isCancelled, let self, self.isArmed else { return }
                self.discard()
            }
        }
    }

    /// Pausing a run that has not actually started is meaningless: while armed,
    /// `.autoPaused` means "clock still frozen, no movement seen yet," not "the
    /// user paused a live run." Refusing the pause here keeps `resumeManually()`
    /// unreachable from the armed state, so it can never re-enter `.recording`
    /// without going through the one-shot `isArmed` rebase in `ingest`.
    func pauseManually() {
        guard !isArmed, state == .recording || state == .autoPaused else { return }
        if state == .recording { advanceTimer(to: clock()) }
        state = .manuallyPaused
        saveCheckpoint(at: clock())
    }

    func resumeManually() {
        guard state == .manuallyPaused else { return }
        autoPause = AutoPauseDetector(activity: activity)
        lastKeptLocation = nil
        pendingGap = !route.isEmpty // fresh segment; gap marker will show honestly
        timeAnchor = clock()
        state = .recording
    }

    /// `endingAt` supplies the true end when the caller knows it — an auto-stop
    /// fires five minutes after the walking actually stopped, and that stationary
    /// tail must not be baked into the workout.
    func finish(endingAt end: Date? = nil) -> RecordedWorkout? {
        guard !isArmed else {
            discard()
            return nil
        }
        provider.stopUpdates()
        if state == .recording { advanceTimer(to: end ?? clock()) }
        let start = startedAt ?? clock()
        let finishedAt = end ?? clock()
        // A backdated start seeds moving time from the walk's beginning; if the
        // walk had already ended by the time we noticed, that seed overshoots the
        // workout's own span. Moving time can never exceed elapsed time.
        let elapsed = max(0, finishedAt.timeIntervalSince(start))
        let workout = RecordedWorkout(type: activity,
                                      start: start,
                                      end: finishedAt,
                                      movingSeconds: min(movingSeconds, elapsed),
                                      distanceMeters: distanceMeters,
                                      route: route,
                                      splitSeconds: splitSeconds,
                                      autoStarted: autoStarted)
        // Keep a final checkpoint: the workout lives only in memory until the user
        // saves or discards the summary, so a kill here must stay recoverable.
        saveCheckpoint(at: clock())
        reset()
        return workout
    }

    func discard() {
        provider.stopUpdates()
        checkpoints.clear()
        reset()
    }

    private func reset() {
        armedTimeoutTask?.cancel()
        armedTimeoutTask = nil
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
        timeAnchor = nil
        pendingGap = false
        autoStarted = false
        gpsBeganAt = nil
        isArmed = false
        lastMovingAt = nil
    }

    // MARK: LocationProvidingDelegate

    func didUpdate(locations: [CLLocation]) {
        for location in locations { ingest(location) }
    }

    func didChangeAuthorization(_ status: CLAuthorizationStatus) {
        authorizationDenied = (status == .denied || status == .restricted)
        reducedAccuracy = provider.accuracyAuthorization == .reducedAccuracy
    }

    func didFail(_ error: Error) {
        // GPS hiccups: keep the session alive; the gap logic handles the hole.
    }

    private func advanceTimer(to time: Date) {
        if let anchor = timeAnchor {
            movingSeconds += max(0, time.timeIntervalSince(anchor))
        }
        timeAnchor = time
    }

    // MARK: Core ingestion

    private func ingest(_ location: CLLocation) {
        guard state == .recording || state == .autoPaused else { return }

        // 1. Timer: wall time accrues sample-to-sample while recording, uncapped —
        //    GPS gaps (tunnels) keep the timer running; only pauses stop it.
        if state == .recording { advanceTimer(to: location.timestamp) }

        // 2. Speed for auto-pause: sensor speed, else computed from last kept point.
        let sensorSpeed = location.speed
        let computedSpeed: Double
        if let last = lastKeptLocation {
            let dt = location.timestamp.timeIntervalSince(last.timestamp)
            computedSpeed = dt > 0 ? location.distance(from: last) / dt : 0
        } else {
            computedSpeed = 0
        }
        let speed = sensorSpeed >= 0 ? sensorSpeed : computedSpeed

        // 3. Feed the detector on EVERY sample so standing still triggers a pause.
        //    A resume starts a fresh timer segment: the paused interval is never credited.
        if var detector = autoPause {
            let wasAutoPaused = state == .autoPaused
            let paused = detector.update(speed: speed, at: location.timestamp)
            autoPause = detector
            if wasAutoPaused && !paused {
                timeAnchor = location.timestamp
                if isArmed {
                    startedAt = location.timestamp
                    isArmed = false
                    armedTimeoutTask?.cancel()
                    armedTimeoutTask = nil
                }
            }
            state = paused ? .autoPaused : .recording
        }

        // 4. Accept or reject the sample.
        let decision = LocationFilter.evaluate(candidate: location,
                                               lastKept: lastKeptLocation,
                                               now: Date())
        guard decision.accepted, state == .recording else { return }
        lastMovingAt = location.timestamp

        // 5. Distance (not across gaps); a resume after pause/relaunch marks the
        //    first point as a gap so the map never draws a line the user didn't move.
        let afterGap = decision.afterGap || pendingGap
        if let last = lastKeptLocation, !afterGap {
            distanceMeters += location.distance(from: last)
        }
        route.append(RoutePoint(lat: location.coordinate.latitude,
                                lon: location.coordinate.longitude,
                                t: location.timestamp,
                                afterGap: afterGap))
        pendingGap = false
        lastKeptLocation = location

        // 6. Km splits.
        let completedKm = Int(distanceMeters / 1000.0)
        while splitSeconds.count < completedKm {
            splitSeconds.append(movingSeconds - lastSplitMovingSeconds)
            lastSplitMovingSeconds = movingSeconds
            onKmSplit?(splitSeconds.count)
        }

        // 7. Periodic checkpoint.
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
