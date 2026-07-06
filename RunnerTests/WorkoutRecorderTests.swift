import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
final class FakeLocationProvider: LocationProviding {
    weak var delegate: LocationProvidingDelegate?
    var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    var started = false
    var stopped = false
    func requestWhenInUseAuthorization() {}
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

    @Test func gapCreditsNoDistance() {
        let (rec, _, _) = makeRecorder()
        rec.start(activity: .run)
        rec.didUpdate(locations: [loc(x: 0, t: 0)])
        rec.didUpdate(locations: [loc(x: 10, t: 4)])
        // signal lost for 60 s, reappears 500 m away
        rec.didUpdate(locations: [loc(x: 510, t: 64)])
        #expect(abs(rec.distanceMeters - 10) < 1)          // 500 m NOT credited
        #expect(rec.route.last?.afterGap == true)
        #expect(rec.movingSeconds < 15)                    // gap interval capped at 10 s
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

    @Test func checkpointsPeriodicallyAndFinishClears() throws {
        let (rec, provider, cp) = makeRecorder(interval: 5)
        rec.start(activity: .walk)
        for i in 0...3 { rec.didUpdate(locations: [loc(x: Double(i) * 10, t: Double(i) * 2)]) }
        #expect(cp.load() != nil)                     // ≥5 s elapsed → checkpointed
        let saved = try #require(cp.load())
        #expect(saved.activity == .walk)
        #expect(saved.distanceMeters > 0)
        let done = rec.finish()
        #expect(provider.stopped)
        #expect(cp.load() == nil)
        #expect(rec.state == .idle)
        #expect(abs(done.distanceMeters - 30) < 2)
        #expect(done.type == .walk)
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

    @Test func deniedAuthorizationSetsFlag() {
        let (rec, _, _) = makeRecorder()
        rec.didChangeAuthorization(.denied)
        #expect(rec.authorizationDenied)
        rec.didChangeAuthorization(.authorizedWhenInUse)
        #expect(rec.authorizationDenied == false)
    }
}
