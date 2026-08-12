import Testing
import Foundation
import CoreLocation
@testable import Runner

/// The three regressions Farid reported after the 1.10 (19) field test:
/// an armed run that un-freezes seconds after arming with no link to the
/// real start, auto-pause that no longer fires when he stops, and auto-resume
/// that no longer fires when he starts again.
///
/// All three share one cause: the auto-pause state machine was fed raw
/// consecutive GPS positions. Over a 1-3 s baseline, position noise alone
/// produces 1-3 m/s of apparent speed, so "standing still" reads as running;
/// and while paused the speed reference was frozen at the last *accepted*
/// sample, so its baseline grew for the whole pause and the estimate decayed
/// to zero, so "running again" read as standing still.
///
/// Sensor speed is unavailable (`-1`) in most of these tests on purpose: that
/// is the case the computed fallback exists for, and the case the field bugs
/// happened in.
@MainActor
struct AutoPauseFeedTests {
    // Anchored near now so LocationFilter's 10 s age check passes; samples in
    // the future relative to `now` pass it too, so long tests stay valid.
    private let base = Date().addingTimeInterval(-2)

    /// `speed: -1` models CoreLocation reporting no Doppler speed.
    private func loc(x: Double, t: TimeInterval,
                     acc: Double = 5, speed: Double = -1) -> CLLocation {
        let lat = 45.5
        let lon = -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180))
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                          altitude: 30, horizontalAccuracy: acc, verticalAccuracy: 10,
                          course: 90, speed: speed, timestamp: base.addingTimeInterval(t))
    }

    private func makeRecorder() -> (WorkoutRecorder, FakeLocationProvider) {
        let provider = FakeLocationProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-tests-\(UUID().uuidString)")
        let recorder = WorkoutRecorder(provider: provider,
                                       checkpoints: CheckpointStore(directory: dir))
        return (recorder, provider)
    }

    /// Standing at the trailhead with the session armed. The fix wanders a few
    /// metres between 1 Hz samples; net displacement stays ~0. The run must NOT
    /// start. This is "ça démarre après quelques secondes sans lien avec le
    /// début de ma course".
    @Test func armedSessionIgnoresStandingStillJitter() {
        let (rec, _) = makeRecorder()
        rec.start(activity: .run, armed: true)

        for i in 0..<25 {
            let jitter = [0.0, 3.0, 1.0, 2.5, 0.5][i % 5]
            rec.didUpdate(locations: [loc(x: jitter, t: Double(i))])
        }

        #expect(rec.isArmed)
        #expect(rec.state == .autoPaused)
        #expect(rec.distanceMeters == 0)
    }

    /// The same armed session must still start promptly once he actually runs.
    @Test func armedSessionStartsOnRealRunning() {
        let (rec, _) = makeRecorder()
        rec.start(activity: .run, armed: true)

        // 3 m/s, 1 Hz. Sustained net displacement, unlike jitter.
        for i in 0...10 { rec.didUpdate(locations: [loc(x: Double(i) * 3, t: Double(i))]) }

        #expect(rec.isArmed == false)
        #expect(rec.state == .recording)
    }

    /// A valid Doppler speed is the fast path: arming must un-freeze on the
    /// first genuinely running sample, with no window to fill.
    @Test func armedSessionStartsImmediatelyOnValidSensorSpeed() {
        let (rec, _) = makeRecorder()
        rec.start(activity: .run, armed: true)

        rec.didUpdate(locations: [loc(x: 0, t: 0, speed: 0.0)])
        #expect(rec.isArmed)
        rec.didUpdate(locations: [loc(x: 3, t: 1, speed: 3.0)])

        #expect(rec.isArmed == false)
        #expect(rec.state == .recording)
    }

    /// He stops running. Position noise keeps arriving; the session must still
    /// reach `.autoPaused` within the 6 s profile. This is "la pause ne
    /// fonctionne plus bien après que je m'arrête".
    @Test func pausesWhileStandingStillDespiteJitter() {
        let (rec, _) = makeRecorder()
        rec.start(activity: .run)

        for i in 0...9 { rec.didUpdate(locations: [loc(x: Double(i) * 3, t: Double(i))]) }
        #expect(rec.state == .recording)

        // Stands still at ~27 m for 15 s; the fix wanders around that point.
        for i in 10...25 {
            let jitter = [27.0, 29.5, 26.5, 28.0, 27.5][(i - 10) % 5]
            rec.didUpdate(locations: [loc(x: jitter, t: Double(i))])
        }

        #expect(rec.state == .autoPaused)
    }

    /// The normal case: CoreLocation does report a Doppler speed, so there is
    /// no window to fill and the aggressive 6 s profile Farid chose applies
    /// literally. (Without Doppler, the displacement fallback cannot beat GPS
    /// noise over less than `SpeedEstimator.minBaseline`, so a stop takes about
    /// 5 s longer to notice — that is a measurement limit, not a policy.)
    @Test func pausesWithinTheProfileWindowWhenDopplerSpeedIsAvailable() {
        let (rec, _) = makeRecorder()
        rec.start(activity: .run)

        for i in 0...9 {
            rec.didUpdate(locations: [loc(x: Double(i) * 3, t: Double(i), speed: 3.0)])
        }
        #expect(rec.state == .recording)

        // t=10 is the first stationary sample, so the 6 s dwell expires at t=16.
        for i in 10...16 {
            rec.didUpdate(locations: [loc(x: 27, t: Double(i), speed: 0.0)])
            if i < 16 { #expect(rec.state == .recording) }  // not before 6 s
        }
        #expect(rec.state == .autoPaused)                   // and not after
    }

    /// A long red light, then he runs again. The speed estimate must not have
    /// decayed with the length of the pause. This is "la reprise après pause a
    /// aussi été brisée".
    @Test func resumesAfterALongPause() {
        let (rec, _) = makeRecorder()
        rec.start(activity: .run)

        for i in 0...9 { rec.didUpdate(locations: [loc(x: Double(i) * 3, t: Double(i))]) }
        for i in 10...25 {
            let jitter = [27.0, 29.5, 26.5, 28.0, 27.5][(i - 10) % 5]
            rec.didUpdate(locations: [loc(x: jitter, t: Double(i))])
        }
        #expect(rec.state == .autoPaused)

        // Two more minutes stopped.
        for i in 26...145 {
            let jitter = [27.0, 29.5, 26.5, 28.0, 27.5][(i - 26) % 5]
            rec.didUpdate(locations: [loc(x: jitter, t: Double(i))])
        }
        #expect(rec.state == .autoPaused)

        // Green light: 3 m/s again.
        for i in 146...156 {
            rec.didUpdate(locations: [loc(x: 27 + Double(i - 146) * 3, t: Double(i))])
        }

        #expect(rec.state == .recording)
    }

    /// The detector used to run before `LocationFilter`, so samples the rest of
    /// the pipeline discards as garbage still drove pause and resume.
    @Test func inaccurateSampleNeverResumesAPausedSession() {
        let (rec, _) = makeRecorder()
        rec.start(activity: .run)

        for i in 0...9 { rec.didUpdate(locations: [loc(x: Double(i) * 3, t: Double(i))]) }
        for i in 10...25 {
            rec.didUpdate(locations: [loc(x: 27, t: Double(i), speed: 0.0)])
        }
        #expect(rec.state == .autoPaused)

        // A 65 m-accuracy fix 60 m away: pure garbage, and a 6 m/s "speed".
        rec.didUpdate(locations: [loc(x: 87, t: 26, acc: 65, speed: 6.0)])

        #expect(rec.state == .autoPaused)
    }
}
