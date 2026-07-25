import Testing
import Foundation
import CoreLocation
@testable import Runner

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

@MainActor
struct WorkoutRecorderTests {
    // Synthetic clock anchored near now so LocationFilter's age check passes.
    private let base = Date().addingTimeInterval(-2)

    private func loc(x: Double, t: TimeInterval, acc: Double = 5, speed: Double = 2.5) -> CLLocation {
        let lat = 45.5
        let lon = -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180))
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                          altitude: 30, horizontalAccuracy: acc, verticalAccuracy: 10,
                          course: 90, speed: speed, timestamp: base.addingTimeInterval(t))
    }

    private func makeRecorder(interval: TimeInterval = 30) -> (WorkoutRecorder, FakeLocationProvider, CheckpointStore) {
        let provider = FakeLocationProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-tests-\(UUID().uuidString)")
        let cp = CheckpointStore(directory: dir)
        let recorder = WorkoutRecorder(provider: provider, checkpoints: cp, checkpointInterval: interval)
        return (recorder, provider, cp)
    }

    @Test func accumulatesDistanceAndMovingTime() {
        let (rec, provider, _) = makeRecorder()
        rec.start(activity: .walk)
        #expect(provider.started)
        // 11 samples, 10 m apart, 4 s apart (2.5 m/s = brisk walk)
        for i in 0...10 { rec.didUpdate(locations: [loc(x: Double(i) * 10, t: Double(i) * 4)]) }
        #expect(abs(rec.distanceMeters - 100) < 2)
        #expect(abs(rec.movingSeconds - 40) < 0.5)
        #expect(rec.route.count == 11)
        #expect(rec.state == .recording)
        #expect(rec.livePoints == 1) // floor(0.1 km × 10)
    }

    @Test func gapCreditsNoDistanceButKeepsTimer() {
        let (rec, _, _) = makeRecorder()
        rec.start(activity: .run)
        rec.didUpdate(locations: [loc(x: 0, t: 0)])
        rec.didUpdate(locations: [loc(x: 10, t: 4)])
        // signal lost for 60 s, reappears 500 m away
        rec.didUpdate(locations: [loc(x: 510, t: 64)])
        #expect(abs(rec.distanceMeters - 10) < 1)          // 500 m NOT credited
        #expect(rec.route.last?.afterGap == true)
        #expect(abs(rec.movingSeconds - 64) < 1)           // spec: timer continues through GPS gaps
    }

    @Test func tunnelKeepsTimerRunning() {
        let (rec, _, _) = makeRecorder()
        rec.start(activity: .run)
        rec.didUpdate(locations: [loc(x: 0, t: 0)])
        rec.didUpdate(locations: [loc(x: 10, t: 4)])
        // 5-minute tunnel: no samples at all, then reacquisition
        rec.didUpdate(locations: [loc(x: 900, t: 304)])
        #expect(rec.movingSeconds > 250)                   // ~all 5 min credited, not 10 s
        #expect(abs(rec.distanceMeters - 10) < 1)          // gap distance still not credited
    }

    @Test func autoPauseCreditsNoPhantomMovingTime() {
        let (rec, _, _) = makeRecorder()
        rec.start(activity: .run)
        rec.didUpdate(locations: [loc(x: 0, t: 0)])
        rec.didUpdate(locations: [loc(x: 10, t: 4)])
        // standing still until auto-pause engages (pauseAfter = 10 s for runs)
        for i in 1...6 {
            rec.didUpdate(locations: [loc(x: 10.5, t: 4 + Double(i) * 2, speed: 0.0)])
        }
        #expect(rec.state == .autoPaused)
        let atPause = rec.movingSeconds
        // 2 minutes standing at a light, samples keep arriving
        for i in 1...10 {
            rec.didUpdate(locations: [loc(x: 10.5, t: 16 + Double(i) * 10, speed: 0.0)])
        }
        // movement resumes (resumeAfter = 3 s)
        rec.didUpdate(locations: [loc(x: 20, t: 120)])
        rec.didUpdate(locations: [loc(x: 26, t: 122)])
        rec.didUpdate(locations: [loc(x: 30, t: 123)])
        #expect(rec.state == .recording)
        // the paused interval credits nothing — no phantom 10 s from the stale fix
        #expect(abs(rec.movingSeconds - atPause) < 0.01)
        rec.didUpdate(locations: [loc(x: 40, t: 127)])
        #expect(abs(rec.movingSeconds - (atPause + 4)) < 0.01)
    }

    @Test func manualResumeMarksNextPointAfterGap() {
        let (rec, _, _) = makeRecorder()
        rec.start(activity: .run)
        rec.didUpdate(locations: [loc(x: 0, t: 0)])
        rec.didUpdate(locations: [loc(x: 10, t: 4)])
        rec.pauseManually()
        rec.resumeManually()
        rec.didUpdate(locations: [loc(x: 200, t: 8)])
        #expect(rec.route.last?.afterGap == true)          // map must break the line here
        #expect(abs(rec.distanceMeters - 10) < 1)          // paused stretch not credited
    }

    @Test func checkpointResumeMarksFirstPointAfterGap() {
        let (rec, _, _) = makeRecorder()
        let checkpoint = SessionCheckpoint(activity: .run, startedAt: base,
                                           movingSeconds: 120, distanceMeters: 800,
                                           route: [RoutePoint(lat: 45.5, lon: -73.6, t: base, afterGap: false)],
                                           splitSeconds: [], savedAt: base)
        rec.start(activity: .run, resumeFrom: checkpoint)
        rec.didUpdate(locations: [loc(x: 5000, t: 0)])
        #expect(rec.route.last?.afterGap == true)          // relaunch point must not join old route
    }

    @Test func autoPausesWhenStandingStill() {
        let (rec, _, _) = makeRecorder()
        rec.start(activity: .run)
        rec.didUpdate(locations: [loc(x: 0, t: 0)])
        rec.didUpdate(locations: [loc(x: 10, t: 4)])
        // standing still: same spot, speed 0, samples every 2 s for 12 s
        for i in 1...6 {
            rec.didUpdate(locations: [loc(x: 10.5, t: 4 + Double(i) * 2, speed: 0.0)])
        }
        #expect(rec.state == .autoPaused)
        let frozen = rec.distanceMeters
        // moving again: ≥3 s above threshold resumes; the first post-resume sample
        // arrives >15 s after the last kept one, so it is a gap point (no distance) —
        // distance grows again from the sample after it.
        rec.didUpdate(locations: [loc(x: 20, t: 20)])
        rec.didUpdate(locations: [loc(x: 30, t: 24)])
        #expect(rec.state == .recording)
        rec.didUpdate(locations: [loc(x: 40, t: 27)])
        #expect(rec.distanceMeters > frozen)
    }

    @Test func manualPauseIgnoresSamples() {
        let (rec, _, _) = makeRecorder()
        rec.start(activity: .bike)
        rec.didUpdate(locations: [loc(x: 0, t: 0)])
        rec.pauseManually()
        #expect(rec.state == .manuallyPaused)
        rec.didUpdate(locations: [loc(x: 100, t: 10)])
        #expect(rec.distanceMeters < 1)
        rec.resumeManually()
        #expect(rec.state == .recording)
    }

    /// Regression: `pauseManually()` persists `isPaused = true` immediately, but
    /// `resumeManually()` used to update only in-memory state — the checkpoint on
    /// disk stayed paused until the next periodic write (up to 30 s later). A
    /// crash inside that window rehydrated an actively-resumed run as paused.
    /// Reload the checkpoint straight off disk, without feeding another location
    /// sample, so a periodic checkpoint from `didUpdate` cannot mask the bug.
    @Test func manualResumeImmediatelyPersistsUnpausedCheckpoint() {
        let (rec, _, cp) = makeRecorder()
        rec.start(activity: .run)
        rec.didUpdate(locations: [loc(x: 0, t: 0)])
        rec.pauseManually()
        rec.resumeManually()
        let saved = cp.load()
        #expect(saved?.isPaused == false)
    }

    @Test func recordsKmSplits() {
        let (rec, _, _) = makeRecorder()
        rec.start(activity: .run)
        var splits: [Int] = []
        rec.onKmSplit = { splits.append($0) }
        // 1,100 m in 110 samples of 10 m, 3 s apart
        for i in 0...110 { rec.didUpdate(locations: [loc(x: Double(i) * 10, t: Double(i) * 3)]) }
        #expect(rec.splitSeconds.count == 1)
        #expect(splits == [1])
        #expect(abs(rec.splitSeconds[0] - 300) < 10) // ~100 samples × 3 s
    }

    @Test func checkpointsPeriodicallyAndFinishKeepsCheckpoint() throws {
        let (rec, provider, cp) = makeRecorder(interval: 5)
        rec.start(activity: .walk)
        for i in 0...3 {
            rec.didUpdate(locations: [loc(x: Double(i) * 10, t: Double(i) * 2)])
        }
        #expect(cp.load() != nil)
        let saved = try #require(cp.load())
        #expect(saved.activity == .walk)
        #expect(saved.distanceMeters > 0)
        let done = try #require(rec.finish())
        #expect(provider.stopped)
        let final = try #require(cp.load())
        #expect(abs(final.distanceMeters - done.distanceMeters) < 0.01)
        #expect(rec.state == .idle)
        #expect(abs(done.distanceMeters - 30) < 2)
        #expect(done.type == .walk)
        cp.clear()
        #expect(cp.load() == nil)
    }

    /// Regression: `end` can be a GPS-derived timestamp (e.g. lastMovingAt)
    /// delivered out of order relative to a rebased `startedAt`, since
    /// SystemLocationProvider hops every delegate callback through an
    /// unstructured Task with no FIFO guarantee. An unclamped `end < start`
    /// would reach HKQuantitySample(start:end:), which raises an uncatchable
    /// ObjC exception — a permanent launch crash loop via retryPendingSaves.
    @Test func finishClampsEndBeforeStartToStart() {
        let (rec, _, _) = makeRecorder()
        rec.start(activity: .run)
        let startedAt = rec.startedAt!
        let earlierEnd = startedAt.addingTimeInterval(-100)
        let workout = rec.finish(endingAt: earlierEnd)
        #expect(workout?.start == startedAt)
        #expect(workout?.end == startedAt)
    }

    @Test func resumeFromCheckpointRestoresProgress() {
        let (rec, _, _) = makeRecorder()
        let checkpoint = SessionCheckpoint(activity: .run, startedAt: base,
                                           movingSeconds: 120, distanceMeters: 800,
                                           route: [RoutePoint(lat: 45.5, lon: -73.6, t: base, afterGap: false)],
                                           splitSeconds: [], savedAt: base)
        rec.start(activity: .run, resumeFrom: checkpoint)
        #expect(rec.distanceMeters == 800)
        #expect(rec.movingSeconds == 120)
        #expect(rec.route.count == 1)
        #expect(rec.state == .recording)
    }

    /// CRITICAL 2 regression: a checkpoint written while manually paused must
    /// rehydrate back into `.manuallyPaused`. Before the fix, `start(resumeFrom:)`
    /// always restored `.recording` regardless of the checkpoint's own state, so
    /// a run that was paused when the process died came back as if actively
    /// recording — the surviving Live Activity's "Resume" button then did the
    /// opposite of what it said on the first tap.
    @Test func resumeFromCheckpointRestoresPausedState() {
        let (rec, _, _) = makeRecorder()
        let checkpoint = SessionCheckpoint(activity: .run, startedAt: base,
                                           movingSeconds: 120, distanceMeters: 800,
                                           route: [RoutePoint(lat: 45.5, lon: -73.6, t: base, afterGap: false)],
                                           splitSeconds: [], savedAt: base, isPaused: true)
        rec.start(activity: .run, resumeFrom: checkpoint)
        #expect(rec.state == .manuallyPaused)
    }

    /// Counterpart: a checkpoint written while actively recording (the common
    /// case, and every checkpoint from before this fix) must still resume as
    /// `.recording` — this fix must not flip the default.
    @Test func resumeFromCheckpointWithoutPauseFlagStillRestoresRecording() {
        let (rec, _, _) = makeRecorder()
        let checkpoint = SessionCheckpoint(activity: .run, startedAt: base,
                                           movingSeconds: 120, distanceMeters: 800,
                                           route: [RoutePoint(lat: 45.5, lon: -73.6, t: base, afterGap: false)],
                                           splitSeconds: [], savedAt: base)
        rec.start(activity: .run, resumeFrom: checkpoint)
        #expect(rec.state == .recording)
    }

    @Test func deniedAuthorizationSetsFlag() {
        let (rec, _, _) = makeRecorder()
        rec.didChangeAuthorization(.denied)
        #expect(rec.authorizationDenied)
        rec.didChangeAuthorization(.authorizedWhenInUse)
        #expect(rec.authorizationDenied == false)
    }

    @Test func startWithReducedAccuracyRequestsPreciseLocation() {
        let (rec, provider, _) = makeRecorder()
        provider.accuracyAuthorization = .reducedAccuracy
        rec.start(activity: .run)
        #expect(provider.fullAccuracyRequests == [WorkoutRecorder.fullAccuracyPurposeKey])
        #expect(rec.reducedAccuracy)                  // UI can explain the silent-zeros session
    }

    @Test func grantingPreciseLocationClearsReducedFlag() {
        let (rec, provider, _) = makeRecorder()
        provider.accuracyAuthorization = .reducedAccuracy
        rec.start(activity: .run)
        #expect(rec.reducedAccuracy)
        provider.accuracyAuthorization = .fullAccuracy
        rec.didChangeAuthorization(.authorizedWhenInUse)
        #expect(rec.reducedAccuracy == false)
    }

    @Test func fullAccuracyStartRequestsNothing() {
        let (rec, provider, _) = makeRecorder()
        rec.start(activity: .walk)
        #expect(provider.fullAccuracyRequests.isEmpty)
        #expect(rec.reducedAccuracy == false)
    }
}
