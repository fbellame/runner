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
    /// into a LATER session (B) that is still armed when A's original
    /// deadline lands. That ordering — A's deadline landing INSIDE B's armed
    /// window, not after B has already ended or before B has begun — is the
    /// only ordering where a leaked timer would actually do damage, so B is
    /// armed at t≈100 (before A's t≈200 deadline) and the assertion window
    /// runs to t≈250, comfortably inside B's own independent deadline of
    /// t≈300.
    ///
    /// Verified (see the task report) that this test does NOT independently
    /// exercise the top-of-`start()` cancel: `discard()` already cancels
    /// session A's task via `reset()`'s own cancel before B's `start()` ever
    /// runs, so removing only the top-of-`start()` cancel does not fail this
    /// test — `reset()`'s cancel alone already covers this discard-then-
    /// later-start ordering. The same is true of the session-token
    /// comparison in isolation, for the same reason. The test only fails
    /// once every independent protection (both cancel sites and the token)
    /// is removed at the same time; it exists to catch a genuine regression
    /// in the cross-session invariant as a whole, not to pin down which
    /// single mechanism is responsible for holding it today.
    @Test func pendingTimeoutFromDiscardedSessionDoesNotCancelNewArmedSession() async {
        let provider = FakeLocationProvider()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("armed-timeout-cross-session-\(UUID().uuidString)")
        let recorder = WorkoutRecorder(
            provider: provider,
            checkpoints: CheckpointStore(directory: directory),
            armedTimeout: .milliseconds(200)
        )

        // Session A: armed, then discarded at t≈0. A's timer, if it leaked,
        // would fire at t≈200.
        recorder.start(activity: .run, armed: true)
        recorder.discard()

        try? await Task.sleep(for: .milliseconds(100))

        // Session B armed at t≈100, so B's own deadline is t≈300. A's
        // deadline (t≈200) now falls INSIDE B's armed window — the real
        // scenario a leaked timer would threaten.
        recorder.start(activity: .run, armed: true)

        // Poll from t≈100 to t≈250: spans A's t≈200 deadline while staying
        // 50 ms clear of B's own t≈300 deadline.
        let deadline = ContinuousClock.now + .milliseconds(150)
        while ContinuousClock.now < deadline {
            #expect(recorder.state == .autoPaused)
            #expect(recorder.isArmed)
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
