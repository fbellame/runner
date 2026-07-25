import Foundation
import CoreLocation
import Observation

struct RecordedWorkout: Codable, Equatable, Sendable {
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
    /// Hoisted out of `liveSnapshot()`: that method runs on every accepted GPS
    /// sample and again on every auto-pause detector tick — up to twice per
    /// sample — and `reducedAccuracy` being true is a persistent per-session
    /// condition, not a one-off. Re-resolving these localized strings from
    /// scratch on every tick would put string-table lookups on the GPS hot
    /// path Phase 2 took explicit care to keep clear of blocking work.
    private static let locationAccessRequiredMessage = String(localized: "Location access is required")
    private static let reducedAccuracyMessage = String(localized: "Precise Location is off")

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
    /// A speed-reference location maintained ONLY until real recording begins
    /// (i.e. only while `lastKeptLocation == nil`). While armed, step 4 returns
    /// early for every sample so `lastKeptLocation` never populates — without
    /// this, the computed-speed fallback in step 2 is permanently 0 and an
    /// armed session can only un-freeze via raw sensor speed, which CoreLocation
    /// reports as -1 (unavailable) for a phone in a pocket. Once `lastKeptLocation`
    /// becomes non-nil this is never consulted again, so existing computed-speed
    /// behaviour after recording starts is completely unchanged.
    private var lastSpeedReference: CLLocation?
    private var autoPause: AutoPauseDetector?
    private var lastCheckpointAt: Date?
    private var lastSplitMovingSeconds: Double = 0
    private var timeAnchor: Date?
    private var pendingGap = false
    private var armedTimeoutTask: Task<Void, Never>?
    // Not `private`: AppModelTests needs to inspect the real announcer wired up
    // by `AppModel.live()` (via `@testable import`) to catch a regression where
    // production wiring silently falls back to `SilentAnnouncer()` again.
    let announcer: any Announcing
    private let liveActivity: any LiveActivityPresenting
    /// The last snapshot published to the Live Activity as `.finished`, kept
    /// around so `completeSave()` (in-app save) and `discard()` (in-app
    /// discard from the summary sheet) each have the real final stats to end
    /// the activity with — `finish()` has already reset the recorder's own
    /// fields by the time either of those fires.
    private var lastFinishedSnapshot: RunActivitySnapshot?
    private var didAnnounceLocationDenied = false
    /// Bumped on every `start()`. Captured by the armed-timeout task so it can
    /// verify, after resuming from sleep, that it still belongs to the session
    /// currently in flight — a structural check independent of where/whether
    /// `armedTimeoutTask?.cancel()` happened to run before it woke up.
    private var sessionToken = 0

    init(provider: LocationProviding,
         checkpoints: CheckpointStore = CheckpointStore(),
         checkpointInterval: TimeInterval = 30,
         armedTimeout: Duration = .seconds(600),
         clock: @escaping () -> Date = { Date() },
         announcer: any Announcing = SilentAnnouncer(),
         liveActivity: any LiveActivityPresenting = SilentLiveActivityPresenter()) {
        self.provider = provider
        self.checkpoints = checkpoints
        self.checkpointInterval = checkpointInterval
        self.armedTimeout = armedTimeout
        self.clock = clock
        self.announcer = announcer
        self.liveActivity = liveActivity
        provider.delegate = self
    }

    func requestPermission() {
        provider.requestWhenInUseAuthorization()
    }

    /// The status a Live Activity should show right now, derived from the
    /// recorder's own state — never stored separately, so it can never drift
    /// from what the recorder actually believes.
    private var liveActivityStatus: RunActivityStatus {
        if authorizationDenied { return .error }
        if isArmed { return .ready }
        switch state {
        case .recording: return .recording
        case .autoPaused, .manuallyPaused: return .paused
        case .idle: return .finished
        }
    }

    private func liveSnapshot(status: RunActivityStatus? = nil) -> RunActivitySnapshot {
        RunActivitySnapshot(
            status: status ?? liveActivityStatus,
            startedAt: startedAt ?? clock(),
            movingSeconds: movingSeconds,
            distanceMeters: distanceMeters,
            paceSecondsPerKm: paceSecondsPerKm,
            reducedAccuracy: reducedAccuracy,
            message: authorizationDenied
                ? Self.locationAccessRequiredMessage
                : reducedAccuracy
                    ? Self.reducedAccuracyMessage
                    : nil
        )
    }

    /// Task 8 connects manual runs only: auto-started sessions (silent by
    /// design — see `AutoWalkCoordinator`) and non-`.run` activities never
    /// get a Live Activity, regardless of `isArmed`/`state`. The `state !=
    /// .idle` clause matters on its own: `activity` defaults to `.run` and
    /// `autoStarted` defaults to `false`, so without it this property reads
    /// `true` before any session has ever started (e.g. the initial location
    /// permission prompt at launch, long before `start()`). `start()` always
    /// assigns `state` (to `.autoPaused` or `.recording`) before its own
    /// `if presentsLiveActivity { liveActivity.begin(...) }` check, so this
    /// clause does not block a session from ever opening its Live Activity.
    private var presentsLiveActivity: Bool {
        state != .idle && activity == .run && !autoStarted
    }

    /// `backdatedTo` starts the workout when the activity really began — before the
    /// app noticed and before GPS was running. The elapsed interval is credited as
    /// moving time up front, so duration is honest from the very first sample.
    func start(activity: ActivityType, resumeFrom checkpoint: SessionCheckpoint? = nil,
               backdatedTo walkBeganAt: Date? = nil, autoStarted: Bool = false,
               armed: Bool = false) {
        // Cancel any pending armed-timeout FIRST, before any other state changes:
        // a new session must never share a window — however brief — where its
        // own `isArmed`/state is live while the previous session's timer is
        // still armed to fire. Every session also gets a fresh token; the
        // timeout task checks both after it wakes.
        armedTimeoutTask?.cancel()
        armedTimeoutTask = nil
        sessionToken += 1
        let session = sessionToken

        self.activity = activity
        self.autoStarted = autoStarted
        self.isArmed = armed && checkpoint == nil && walkBeganAt == nil
        didAnnounceLocationDenied = false
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
        // CRITICAL 2: a checkpoint written while manually paused must rehydrate
        // back into `.manuallyPaused`, not `.recording` — otherwise a Live
        // Activity surviving process death keeps showing "Resume" over a
        // session the recorder now believes is actively recording, and the
        // first tap does the opposite of what the button says.
        state = self.isArmed ? .autoPaused
            : (checkpoint?.isPaused == true ? .manuallyPaused : .recording)
        // Approximate location (~km accuracy) fails the filter's 30 m gate, so the
        // session would silently record nothing: ask for precise, and flag the UI.
        reducedAccuracy = provider.accuracyAuthorization == .reducedAccuracy
        if reducedAccuracy {
            provider.requestTemporaryFullAccuracy(purposeKey: Self.fullAccuracyPurposeKey)
        }
        provider.startUpdates()
        if presentsLiveActivity {
            liveActivity.begin(liveSnapshot())
        }
        if isArmed {
            let timeout = armedTimeout
            armedTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                // Re-check after the suspension, not only before: isArmed may
                // have changed while asleep (movement started, or the session
                // was finished/discarded/reset). The session-token comparison
                // is an independent identity check, not load-bearing today —
                // the cancel at the very top of start() already guarantees
                // Task.isCancelled for any stale task by the time a new
                // session exists, so no black-box test can force this
                // comparison to be the deciding factor. It exists so the
                // invariant survives a future edit that removes, relocates,
                // or bypasses that cancel — a class of change that would
                // otherwise fail silently.
                guard !Task.isCancelled, let self,
                      self.isArmed, self.sessionToken == session else { return }
                // Unreachable for auto-walks today only via a cross-file invariant:
                // AutoWalkCoordinator always passes a non-nil `backdatedTo`, which
                // forces `isArmed` false, so no timeout task is ever created for an
                // auto-started session. Guard locally too, for uniformity with every
                // other announcement site, so the silence AutoWalkCoordinator relies
                // on doesn't depend on that invariant holding elsewhere.
                if !self.autoStarted {
                    self.announcer.announce(.runCancelled)
                }
                self.discardArmedSession()
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
        // If the session was already `.autoPaused`, `ingest`'s auto-pause branch has
        // already announced `.paused` for this same real-world stop — the user tapping
        // the (still-enabled) pause button here is not a second stop, and must not
        // speak a second "Paused". Capture the prior state before mutating it.
        let wasRecording = state == .recording
        if wasRecording { advanceTimer(to: clock()) }
        state = .manuallyPaused
        saveCheckpoint(at: clock())
        if wasRecording, !autoStarted { announcer.announce(.paused) }
        if presentsLiveActivity {
            liveActivity.update(liveSnapshot())
        }
    }

    // No symmetric double-announce risk here: this is reachable ONLY from
    // `.manuallyPaused` (the guard below), and the only path into `.manuallyPaused`
    // is `pauseManually`, so there is exactly one `resumeManually` per pause. Unlike
    // `pauseManually`, it always announces — even when the prior stop was originally
    // an auto-pause — because the tap itself is the user's own explicit "resume"
    // action and deserves its own confirmation, distinct from whatever announced
    // (or didn't) the stop that preceded it.
    func resumeManually() {
        guard state == .manuallyPaused else { return }
        autoPause = AutoPauseDetector(activity: activity)
        lastKeptLocation = nil
        pendingGap = !route.isEmpty // fresh segment; gap marker will show honestly
        timeAnchor = clock()
        state = .recording
        if !autoStarted { announcer.announce(.resumed) }
        if presentsLiveActivity {
            liveActivity.update(liveSnapshot())
        }
    }

    /// `endingAt` supplies the true end when the caller knows it — an auto-stop
    /// fires five minutes after the walking actually stopped, and that stationary
    /// tail must not be baked into the workout.
    func finish(endingAt end: Date? = nil) -> RecordedWorkout? {
        // A session that has already been reset (e.g. the armed timeout fired
        // in the same MainActor turn a slide-to-finish landed) has no real
        // span to report; building a workout here would offer the user a
        // bogus 0.00 km summary with start == end.
        guard state != .idle else { return nil }
        guard !isArmed else {
            discardArmedSession()
            return nil
        }
        provider.stopUpdates()
        if state == .recording { advanceTimer(to: end ?? clock()) }
        let start = startedAt ?? clock()
        // `end` may be a GPS-derived timestamp (recorder.lastMovingAt) delivered out
        // of order relative to a rebased `startedAt` — SystemLocationProvider hops
        // every delegate callback through an unstructured Task, which is not
        // FIFO-guaranteed. Without this clamp, end < start would reach HealthKit's
        // HKQuantitySample(start:end:), which raises an uncatchable ObjC exception.
        let finishedAt = max(start, end ?? clock())
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
        if presentsLiveActivity {
            // Publish `.finished` now (before `reset()` zeroes the stats this
            // reads), but don't end the activity yet — the lock screen should
            // keep showing the final numbers until the summary sheet is
            // actually saved or discarded, not vanish the instant the user
            // slides to finish.
            let snapshot = liveSnapshot(status: .finished)
            lastFinishedSnapshot = snapshot
            liveActivity.update(snapshot)
        }
        reset()
        return workout
    }

    /// In-app discard, from the summary sheet's "Discard" button. `finish()`
    /// has already reset the recorder by the time this runs, so a captured
    /// `lastFinishedSnapshot` — carrying the real final stats — takes
    /// priority over a freshly-computed (and by now zeroed-out) snapshot.
    /// The `presentsLiveActivity` fallback exists for a hypothetical future
    /// call site that discards a still-active session directly, without
    /// going through `finish()` first. This order is now also structurally
    /// reinforced by `presentsLiveActivity`'s own `state != .idle` clause:
    /// after `reset()`, `state == .idle` makes `presentsLiveActivity` false,
    /// so the two branches can no longer both read true for the same call —
    /// this doc comment's ordering rationale is kept explicit anyway, since
    /// that clause lives on a different property for an unrelated reason
    /// (Minor 6) and nothing enforces the two staying in sync.
    func discard() {
        if let lastFinishedSnapshot {
            liveActivity.end(lastFinishedSnapshot)
        } else if presentsLiveActivity {
            liveActivity.end(liveSnapshot(status: .finished))
        }
        lastFinishedSnapshot = nil
        provider.stopUpdates()
        checkpoints.clear()
        reset()
    }

    /// Confirms a save out loud — the one cue that answers the core question of
    /// this phase for a user who cannot see the screen: "did it record at all?"
    ///
    /// RESOLVED TASK 8 COLLISION: this used to be called directly from
    /// `RecordView.save(_:)`. Task 8 added `completeSave()`, which also needs
    /// to end the Live Activity on save — and its natural call site is the
    /// exact line `announceSaved()` already occupied. Rather than have both
    /// announce (which would say "Run saved. Run saved."), `completeSave()`
    /// below calls this method instead of announcing directly, and
    /// `RecordView.save(_:)` now calls `completeSave()` in place of
    /// `announceSaved()`. This method stays `internal` (not folded into
    /// `completeSave()`) because Task 12's intent-driven save (finishing from
    /// the Lock Screen) is a genuinely separate call site that needs its own
    /// "Run saved" cue but has no Live Activity snapshot of its own to end.
    func announceSaved() {
        announcer.announce(.runSaved)
    }

    /// IN-APP SAVE PATH ONLY: called from `RecordView.save(_:)`, replacing
    /// the `announceSaved()` call that used to sit there (see its doc comment
    /// above). Speaks "Run saved" exactly once via `announceSaved()`, then
    /// ends the Live Activity using the stats `finish()` captured — the
    /// recorder itself has already been reset by this point, so there is no
    /// live state left to build a snapshot from.
    ///
    /// CRITICAL 2 fix: `RecordView.save(_:)` calls this for every activity
    /// type the UI offers (run, walk, bike), but `lastFinishedSnapshot` is
    /// only ever assigned for `.run` (`presentsLiveActivity` gates it — see
    /// that property's doc comment). The announcement must not be gated by
    /// that: a manual walk or bike save answers the same "did it record at
    /// all?" question Phase 2 exists for, and has no Live Activity to end.
    /// Only the teardown stays conditional on there being a snapshot to end.
    func completeSave() {
        announceSaved()
        guard let snapshot = lastFinishedSnapshot else { return }
        liveActivity.end(snapshot)
        lastFinishedSnapshot = nil
    }

    /// CRITICAL 3 fix: the seam `AppModel` uses to end a Live Activity
    /// stranded by a crash — "Save as-is" and Discard on the resume prompt
    /// never call `start()`/`finish()`/`discard()` on THIS recorder instance
    /// (there is no in-memory session to resume; the workout is built
    /// straight from the on-disk checkpoint), so none of this recorder's own
    /// state changes. `liveActivity` stays `private`; this is the minimal
    /// forwarding that lets `AppModel` reach `endAllSurvivingActivities()`
    /// without exposing the presenter itself.
    func endStrandedLiveActivity() {
        liveActivity.endAllSurvivingActivities()
    }

    /// CRITICAL 4 fix: Cancel on `RecordView`'s authorization-denied overlay.
    /// GPS access was just revoked, so the recorder cannot keep recording —
    /// but Cancel is not Discard: the user didn't ask to throw the run away,
    /// only to back out of a session that can no longer track them. Unlike
    /// `discard()`, the on-disk checkpoint is left untouched (not cleared),
    /// so the crash-resume prompt can still recover it on next launch. Unlike
    /// `finish()`, no `RecordedWorkout` is returned — there is no summary
    /// sheet to show for a session the user backed out of via Cancel rather
    /// than sliding to finish. Ends any stranded `.error` Live Activity and
    /// returns the recorder to `.idle` either way.
    func cancelAfterAuthorizationDenial() {
        guard state != .idle else { return }
        guard !isArmed else {
            // An armed session has never recorded real progress — no sample
            // has been accepted yet, so `saveCheckpoint` below would write a
            // bogus zero-distance checkpoint over whatever legitimate PRIOR
            // session's recovery copy is on disk. `discardArmedSession`
            // already does exactly what's needed here (ends the Live
            // Activity if presented, stops updates, resets) without
            // touching the checkpoint at all.
            discardArmedSession()
            return
        }
        if state == .recording { advanceTimer(to: clock()) }
        saveCheckpoint(at: clock())
        if presentsLiveActivity {
            liveActivity.end(liveSnapshot(status: .finished))
        }
        provider.stopUpdates()
        reset()
    }

    /// Both armed exit paths (finish()'s `isArmed` early-return, and the armed
    /// timeout) route here instead of `discard()`. An armed session never writes
    /// a checkpoint of its own — `saveCheckpoint` is reachable only from step 7 of
    /// `ingest` (requires `state == .recording`) and from `pauseManually` (refused
    /// while armed) — so any checkpoint on disk at this point belongs to a PRIOR
    /// session (e.g. one whose summary sheet was swiped away). Clearing it here
    /// would destroy that unrelated recovery copy for no reason.
    ///
    /// An armed session that reaches here (timed out, or slid-to-finish while
    /// still armed) never ran `finish()`, so it never captured a
    /// `lastFinishedSnapshot` — end the Live Activity from a freshly-built
    /// `.finished` snapshot instead, same as `discard()`'s fallback branch.
    private func discardArmedSession() {
        if presentsLiveActivity {
            liveActivity.end(liveSnapshot(status: .finished))
        }
        provider.stopUpdates()
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
        lastSpeedReference = nil
        lastCheckpointAt = nil
        autoPause = nil
        lastSplitMovingSeconds = 0
        timeAnchor = nil
        pendingGap = false
        autoStarted = false
        gpsBeganAt = nil
        isArmed = false
        lastMovingAt = nil
        didAnnounceLocationDenied = false
    }

    // MARK: LocationProvidingDelegate

    func didUpdate(locations: [CLLocation]) {
        for location in locations { ingest(location) }
    }

    func didChangeAuthorization(_ status: CLAuthorizationStatus) {
        authorizationDenied = (status == .denied || status == .restricted)
        reducedAccuracy = provider.accuracyAuthorization == .reducedAccuracy
        if authorizationDenied, state != .idle, !autoStarted, !didAnnounceLocationDenied {
            didAnnounceLocationDenied = true
            announcer.announce(.locationDenied)
        }
        // `presentsLiveActivity` itself now folds in `state != .idle` (see
        // its doc comment), so the redundant local check that used to live
        // here is gone.
        if presentsLiveActivity {
            liveActivity.update(liveSnapshot())
        }
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
        } else if let reference = lastSpeedReference {
            let dt = location.timestamp.timeIntervalSince(reference.timestamp)
            computedSpeed = dt > 0 ? location.distance(from: reference) / dt : 0
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
                let wasArmed = isArmed
                if isArmed {
                    startedAt = location.timestamp
                    isArmed = false
                    armedTimeoutTask?.cancel()
                    armedTimeoutTask = nil
                }
                if !autoStarted {
                    announcer.announce(wasArmed ? .runStarted : .resumed)
                }
            } else if !wasAutoPaused && paused && !autoStarted {
                announcer.announce(.paused)
            }
            state = paused ? .autoPaused : .recording
            if presentsLiveActivity {
                liveActivity.update(liveSnapshot())
            }
        }

        // 4. Accept or reject the sample.
        let decision = LocationFilter.evaluate(candidate: location,
                                               lastKept: lastKeptLocation,
                                               now: Date())
        if decision.accepted, state == .recording {
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

            if presentsLiveActivity {
                liveActivity.update(liveSnapshot())
            }
        }

        // 8. Speed reference for step 2's fallback: kept alive only until real
        //    recording starts (see property doc). This is the one path reachable
        //    while armed, since step 4 never sets lastKeptLocation in that state.
        if lastKeptLocation == nil {
            lastSpeedReference = location
        }
    }

    private func saveCheckpoint(at time: Date) {
        guard let startedAt else { return }
        // CRITICAL 2: record whether the session is manually paused right now,
        // so a later `start(resumeFrom:)` can restore that state instead of
        // always resuming as `.recording`.
        let checkpoint = SessionCheckpoint(activity: activity, startedAt: startedAt,
                                           movingSeconds: movingSeconds,
                                           distanceMeters: distanceMeters,
                                           route: route, splitSeconds: splitSeconds,
                                           savedAt: time, isPaused: state == .manuallyPaused)
        try? checkpoints.save(checkpoint)
        lastCheckpointAt = time
    }
}
