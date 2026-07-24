import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
struct ArmedTimeoutTests {
    /// Polls `condition` until it's true or `timeout` elapses, instead of a
    /// single fixed sleep. swift-testing runs `@MainActor` suites in parallel
    /// on one executor, so a tight fixed-sleep margin (e.g. 20 ms timer / 60 ms
    /// wait) can produce a false RED under load. Polling with a generous cap
    /// keeps the test fast on a healthy machine and still correct on a loaded one.
    private func waitUntil(timeout: Duration = .seconds(2),
                            pollEvery interval: Duration = .milliseconds(10),
                            _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: interval)
        }
    }

    @Test func armedSessionCancelsAfterConfiguredTimeoutWithoutMovement() async {
        let provider = FakeLocationProvider()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("armed-timeout-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(directory: directory)
        let recorder = WorkoutRecorder(
            provider: provider,
            checkpoints: checkpoints,
            armedTimeout: .milliseconds(20)
        )

        recorder.start(activity: .run, armed: true)
        await waitUntil { recorder.state == .idle }

        #expect(recorder.state == .idle)
        #expect(!recorder.isArmed)
        #expect(provider.stopped)
        #expect(checkpoints.load() == nil)
    }

    @Test func timeoutDoesNotCancelAfterMovementStarts() async {
        let provider = FakeLocationProvider()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("armed-timeout-moving-\(UUID().uuidString)")
        let recorder = WorkoutRecorder(
            provider: provider,
            checkpoints: CheckpointStore(directory: directory),
            armedTimeout: .milliseconds(50)
        )
        let base = Date()
        func location(_ seconds: TimeInterval) -> CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: 45.5,
                    longitude: -73.6 + seconds / 100_000
                ),
                altitude: 30,
                horizontalAccuracy: 5,
                verticalAccuracy: 10,
                course: 90,
                speed: 2,
                timestamp: base.addingTimeInterval(seconds)
            )
        }

        recorder.start(activity: .run, armed: true)
        recorder.didUpdate(locations: [location(0), location(3)])

        // Poll across a window comfortably longer than armedTimeout, asserting
        // at every step rather than only once at the end: this both survives
        // scheduling jitter and catches a transient flip that a single
        // end-of-wait check would miss.
        let deadline = ContinuousClock.now + .milliseconds(300)
        while ContinuousClock.now < deadline {
            #expect(recorder.state == .recording)
            #expect(!recorder.isArmed)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Covers the failure mode a stale armed-timeout task could cause: a
    /// timer belonging to an already-discarded session (A) must never reach
    /// into a session started afterwards (B), even once real time has passed
    /// A's original deadline. Session A is armed and discarded immediately;
    /// after a real gap well past A's timeout, session B is armed on the same
    /// recorder and must stay alive through a window safely inside its own
    /// (independent, freshly-started) timeout.
    @Test func pendingTimeoutFromDiscardedSessionDoesNotCancelNewArmedSession() async {
        let provider = FakeLocationProvider()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("armed-timeout-cross-session-\(UUID().uuidString)")
        let recorder = WorkoutRecorder(
            provider: provider,
            checkpoints: CheckpointStore(directory: directory),
            armedTimeout: .milliseconds(30)
        )

        // Session A: armed, then discarded before its own timer can fire.
        recorder.start(activity: .run, armed: true)
        recorder.discard()

        // Let real time pass well beyond what A's timer deadline would have
        // been, so a leaked/uncancelled task for A has every opportunity to
        // misfire here, before B even exists.
        try? await Task.sleep(for: .milliseconds(60))

        // Session B starts only now. A properly-isolated implementation must
        // not let A's stale timer discard B.
        recorder.start(activity: .run, armed: true)

        // Poll through a window comfortably inside B's own 30 ms deadline.
        let deadline = ContinuousClock.now + .milliseconds(15)
        while ContinuousClock.now < deadline {
            #expect(recorder.state == .autoPaused)
            #expect(recorder.isArmed)
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
