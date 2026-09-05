import Foundation
import Observation

/// Turns motion samples into recorded walks. Walking is by far the most common
/// activity and the one most often lost to forgetting to press Record, so a walk
/// that has been going for five minutes records itself, and stops itself five
/// minutes after the walking does.
///
/// Deliberately silent: nothing is announced, nothing is prompted. That places the
/// burden on this type to refuse to record rubbish, since no one is watching.
@MainActor
@Observable
final class AutoWalkCoordinator {
    /// Below this, a detected walk is assumed to be a misread and is discarded
    /// rather than saved — the same floor `RecordedWorkout.pace` uses to decide
    /// there is too little signal to mean anything.
    static let minimumDistanceMeters: Double = 100
    /// How far back to look on foreground for a walk that began while the app was
    /// closed. CoreMotion's history is sparser than its live stream on some
    /// devices; widen this if walks are being missed.
    static let historyLookback: TimeInterval = 30 * 60

    private let motion: MotionActivityProviding
    private let recorder: WorkoutRecorder
    private let health: HealthStoring
    private let checkpoints: CheckpointStore
    private let clock: () -> Date
    /// Everything the coordinator needs to know about the rest of the app, without
    /// reaching into AppModel and creating a cycle.
    private let canAutoStart: () -> Bool
    /// Returns whether the durable local copy landed; a walk whose save failed
    /// must keep its checkpoint (CRITICAL 5).
    private let save: (RecordedWorkout) async -> Bool

    private var detector = WalkDetector()
    private var isObserving = false
    /// The newest sample the detector has seen. Every foreground re-queries the
    /// same 30-minute window, so without this the detector would eat samples it
    /// already consumed live and re-open a walk that has long since ended.
    private var lastSampleAt: Date?

    /// True while a session this coordinator opened is running. A manual session
    /// is none of its business.
    private(set) var isAutoSession = false

    init(motion: MotionActivityProviding,
         recorder: WorkoutRecorder,
         health: HealthStoring,
         // No default: it must be the same store the recorder writes to, or a
         // saved walk would leave a stale checkpoint behind.
         checkpoints: CheckpointStore,
         clock: @escaping () -> Date = { Date() },
         canAutoStart: @escaping () -> Bool,
         save: @escaping (RecordedWorkout) async -> Bool) {
        self.motion = motion
        self.recorder = recorder
        self.health = health
        self.checkpoints = checkpoints
        self.clock = clock
        self.canAutoStart = canAutoStart
        self.save = save
    }

    /// Absent motion authorization the whole feature is a no-op and the app behaves
    /// exactly as it did before. That is a valid answer, not an error.
    func requestAuthorization() async {
        guard motion.isAvailable else { return }
        await motion.requestAuthorization()
    }

    /// Replays the recent past through the detector, then attaches the live stream.
    /// The detector reads sample timestamps rather than a clock, so a walk begun
    /// while the app was closed lands exactly as it would have live.
    func onForeground() async {
        guard motion.isAvailable, motion.isAuthorized else { return }
        let now = clock()
        for sample in await motion.history(from: now - Self.historyLookback, to: now) {
            await ingest(sample)
        }
        guard !isObserving else { return }
        isObserving = true
        motion.startUpdates { [weak self] sample in
            Task { @MainActor in await self?.ingest(sample) }
        }
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false
        motion.stopUpdates()
    }

    /// The single entry point for a sample, live or replayed from history.
    /// The detector reasons from sample timestamps, so it must only ever move
    /// forward in time: a sample it has already seen, or one that arrives out of
    /// order, is dropped.
    func ingest(_ sample: MotionSample) async {
        if let last = lastSampleAt, sample.at <= last { return }
        lastSampleAt = sample.at
        switch detector.update(sample) {
        case .start(let walkBeganAt):
            autoStart(walkBeganAt: walkBeganAt)
        case .stop(let lastWalkingAt):
            await autoStop(lastWalkingAt: lastWalkingAt)
        case nil:
            break
        }
    }

    private func autoStart(walkBeganAt: Date) {
        // A manually started run must never be hijacked, and an unanswered
        // crash-resume prompt still owns the recorder.
        //
        // CRITICAL 1 (regression fix): `autoStop()` clears `isAutoSession` and
        // `finish()` leaves the recorder `.idle` even when a silent save fails
        // and its checkpoint is deliberately retained for recovery — so both
        // in-memory ownership guards above release the instant that happens,
        // while the checkpoint the failed save left behind is still sitting on
        // disk. Without this, the very next walk would auto-start a fresh
        // session whose own periodic checkpoint writes land on the same file
        // and silently destroy the only surviving copy of the failed one.
        // Consulting the store directly closes that gap regardless of which
        // process wrote the retained checkpoint or how long ago: a later
        // auto-start can never overwrite a checkpoint no one has resolved yet.
        guard canAutoStart(), recorder.state == .idle, !isAutoSession,
              checkpoints.load() == nil else { return }
        isAutoSession = true
        recorder.start(activity: .walk, backdatedTo: walkBeganAt, autoStarted: true)
    }

    private func autoStop(lastWalkingAt: Date) async {
        guard isAutoSession else { return }
        isAutoSession = false
        let gpsBeganAt = recorder.gpsBeganAt
        let walkBeganAt = recorder.startedAt
        // The stationary tail that triggered this stop is not part of the walk.
        // `requiringDistance: false`: a detected walk routinely finishes with
        // zero GPS metres because the walk started before GPS did — the Health
        // backfill below is what gives it its distance. The 100 m floor further
        // down is this path's own, stricter version of the same rule.
        guard var workout = recorder.finish(endingAt: lastWalkingAt,
                                            requiringDistance: false) else {
            recorder.discard()
            return
        }

        // The minutes before detection have duration but no route: GPS was not yet
        // running. Health saw the steps, so take the distance from there.
        // A walk replayed from history may have ended before GPS ever started, so
        // the window closes at whichever came first.
        var backfilled: Double = 0
        if let gpsBeganAt, let walkBeganAt {
            let until = min(gpsBeganAt, workout.end)
            if until > walkBeganAt {
                backfilled = (try? await health.walkRunDistance(from: walkBeganAt, to: until)) ?? 0
            }
        }
        if backfilled > 0 {
            workout = RecordedWorkout(type: workout.type, start: workout.start, end: workout.end,
                                      movingSeconds: workout.movingSeconds,
                                      distanceMeters: workout.distanceMeters + backfilled,
                                      route: workout.route, splitSeconds: workout.splitSeconds,
                                      distanceEstimated: true, autoStarted: true)
        }

        // Nobody is watching a silent save, so the junk filter has to live here.
        guard workout.distanceMeters >= Self.minimumDistanceMeters else {
            recorder.discard()
            return
        }
        // finish() leaves a checkpoint behind so a crash between finish and save
        // stays recoverable. Only clear it once the durable copy really landed:
        // otherwise this silent path would destroy the walk's only record and
        // nobody would ever hear about it (CRITICAL 5).
        guard await save(workout) else { return }
        checkpoints.clear()
    }
}
