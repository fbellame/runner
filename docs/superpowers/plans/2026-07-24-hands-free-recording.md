# Hands-Free Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an iPhone-only Runner user arm, monitor, pause, resume, finish, and save an honestly timed run from the Lock Screen with spoken AirPods feedback.

**Architecture:** `WorkoutRecorder` remains the single session state machine and gains armed-start and tail-trim state plus narrow `Announcing` and `LiveActivityPresenting` dependencies. `AppModel` owns the intent-facing save orchestration, while a presentation-only `RunnerWidgets` extension shares `RunAttributes` with the app and mirrors compiler-only intent declarations; persistence continues through `SyncCoordinator.saveRecorded(_:)`.

**Tech Stack:** Swift 6, SwiftUI, Observation, CoreLocation, AVFoundation, ActivityKit, WidgetKit Controls, App Intents, SwiftData, swift-testing, XcodeGen, iOS 18.

## Global Constraints

- Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`. All UI/recorder types are `@MainActor`. New protocols crossing actor boundaries need `Sendable` care.
- Deployment target iOS 18.0. Controls API (`ControlWidget`) is iOS 18+; `LiveActivityIntent` is iOS 17+; ActivityKit is iOS 16.1+. All are available.
- iPhone only (`TARGETED_DEVICE_FAMILY: "1"`).
- Tests use **swift-testing**, not XCTest: `import Testing`, `struct XTests { @Test func name() { #expect(...) } }`. Follow RunnerTests/AutoPauseTests.swift exactly.
- `project.yml` is the source of truth. After ANY change to it, run `xcodegen generate`. Never hand-edit `Runner.xcodeproj`.
- Test command: `xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20`
- Build command: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -20`
- 248 tests currently pass; the suite must stay green at every commit.
- User-facing strings are localized en + fr in `Runner/Resources/Localizable.xcstrings`. CRITICAL: that file has pre-existing duplicate keys — it must NEVER be parsed and re-serialized as JSON. Edit it TEXTUALLY only.
- Version bump to 1.10 in BOTH `project.yml` and `Runner/Info.plist` (they must agree).
- Preserve `AutoWalkCoordinator`'s direct, silent `await save(workout)` path. It must never announce or open a Live Activity.
- All three system actions conform to `LiveActivityIntent`, not plain `AppIntent`. Apple runs a `LiveActivityIntent` in the app process, which is what gives it access to the registered `AppModel`; replacing it with `AppIntent` moves execution to the extension and breaks recorder control.
- Phase 1 ships standalone with zero new targets. Complete and commit every phase in order.

---

## Phase 1 — Honest Timing

### Task 1: Construct the auto-pause detector in an armed state

**Files:**
- Modify: `Runner/Core/Recording/AutoPauseDetector.swift`
- Create: `RunnerTests/AutoPauseArmingTests.swift`

**Interfaces**

- **Consumes:** `AutoPauseDetector.init(activity: ActivityType)` and `mutating func update(speed: Double, at time: Date) -> Bool`.
- **Produces:** `AutoPauseDetector.init(activity: ActivityType, startPaused: Bool = false)` and the unchanged `mutating func update(speed: Double, at time: Date) -> Bool`.

- [ ] **1. Write the failing test.** Create `RunnerTests/AutoPauseArmingTests.swift` with the complete contents:

```swift
import Testing
import Foundation
@testable import Runner

struct AutoPauseArmingTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)
    private func t(_ seconds: TimeInterval) -> Date {
        base.addingTimeInterval(seconds)
    }

    @Test func armedDetectorStaysPausedUntilThreeContinuousMovingSeconds() {
        var detector = AutoPauseDetector(activity: .run, startPaused: true)

        #expect(detector.isPaused)
        #expect(detector.update(speed: 2.0, at: t(0)) == true)
        #expect(detector.update(speed: 2.0, at: t(2)) == true)
        #expect(detector.update(speed: 2.0, at: t(3)) == false)
    }

    @Test func armedDetectorResetsItsResumeWindowAfterABriefBlip() {
        var detector = AutoPauseDetector(activity: .run, startPaused: true)

        #expect(detector.update(speed: 2.0, at: t(0)) == true)
        #expect(detector.update(speed: 0.1, at: t(2)) == true)
        #expect(detector.update(speed: 2.0, at: t(3)) == true)
        #expect(detector.update(speed: 2.0, at: t(5)) == true)
        #expect(detector.update(speed: 2.0, at: t(6)) == false)
    }

    @Test func existingConstructionStillStartsUnpaused() {
        let detector = AutoPauseDetector(activity: .run)
        #expect(!detector.isPaused)
    }
}
```

- [ ] **2. Run it and verify RED.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected failure:

```text
error: extra argument 'startPaused' in call
** TEST FAILED **
```

- [ ] **3. Write the minimal implementation.** Replace the initializer and the `isPaused` declaration in `AutoPauseDetector.swift` with:

```swift
    private(set) var isPaused: Bool
    private var belowSince: Date?
    private var aboveSince: Date?

    init(activity: ActivityType, startPaused: Bool = false) {
        self.isPaused = startPaused
        switch activity {
        case .run, .walk:
            pauseSpeedThreshold = 0.5
            pauseAfter = 10
        case .bike:
            pauseSpeedThreshold = 1.0
            pauseAfter = 15
        }
    }
```

Do not change `update(speed:at:)`; its existing paused branch already supplies the exact three-second continuous-motion rule.

- [ ] **4. Run the complete suite and verify GREEN.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected output:

```text
** TEST SUCCEEDED **
```

- [ ] **5. Commit.**

```bash
git add Runner/Core/Recording/AutoPauseDetector.swift RunnerTests/AutoPauseArmingTests.swift
git commit -m "feat: add armed auto-pause construction"
```

### Task 2: Arm the recorder and rebase `startedAt` exactly once

**Files:**
- Modify: `Runner/Core/Recording/WorkoutRecorder.swift`
- Create: `RunnerTests/ArmedWorkoutRecorderTests.swift`

**Interfaces**

- **Consumes:** `AutoPauseDetector.init(activity: ActivityType, startPaused: Bool = false)`, `WorkoutRecorder.start(activity:resumeFrom:backdatedTo:autoStarted:)`, `advanceTimer(to: Date)`, `timeAnchor: Date?`, and `state: WorkoutRecorder.State`.
- **Produces:** `private(set) var isArmed: Bool` and `func start(activity: ActivityType, resumeFrom checkpoint: SessionCheckpoint? = nil, backdatedTo walkBeganAt: Date? = nil, autoStarted: Bool = false, armed: Bool = false)`.

- [ ] **1. Write the failing test.** Create `RunnerTests/ArmedWorkoutRecorderTests.swift`:

```swift
import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
struct ArmedWorkoutRecorderTests {
    private let base = Date().addingTimeInterval(-2)

    private func location(x: Double, seconds: TimeInterval,
                          speed: Double) -> CLLocation {
        let longitude = -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180))
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 45.5, longitude: longitude),
            altitude: 30,
            horizontalAccuracy: 5,
            verticalAccuracy: 10,
            course: 90,
            speed: speed,
            timestamp: base.addingTimeInterval(seconds)
        )
    }

    private func makeRecorder() -> WorkoutRecorder {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("armed-recorder-\(UUID().uuidString)")
        return WorkoutRecorder(
            provider: FakeLocationProvider(),
            checkpoints: CheckpointStore(directory: directory),
            clock: { base }
        )
    }

    @Test func armedStartFreezesTheClockUntilMovement() {
        let recorder = makeRecorder()
        recorder.start(activity: .run, armed: true)

        #expect(recorder.state == .autoPaused)
        #expect(recorder.isArmed)
        #expect(recorder.movingSeconds == 0)

        recorder.didUpdate(locations: [
            location(x: 0, seconds: 10, speed: 2),
            location(x: 4, seconds: 12, speed: 2)
        ])

        #expect(recorder.state == .autoPaused)
        #expect(recorder.movingSeconds == 0)

        recorder.didUpdate(locations: [
            location(x: 8, seconds: 13, speed: 2)
        ])

        #expect(recorder.state == .recording)
        #expect(!recorder.isArmed)
        #expect(recorder.startedAt == base.addingTimeInterval(13))
        #expect(recorder.movingSeconds == 0)
    }

    @Test func secondAutoPauseCycleDoesNotRebaseStartedAt() {
        let recorder = makeRecorder()
        recorder.start(activity: .run, armed: true)
        recorder.didUpdate(locations: [
            location(x: 0, seconds: 0, speed: 2),
            location(x: 4, seconds: 3, speed: 2)
        ])
        let firstRebase = recorder.startedAt

        recorder.didUpdate(locations: [
            location(x: 4, seconds: 4, speed: 0),
            location(x: 4, seconds: 14, speed: 0)
        ])
        #expect(recorder.state == .autoPaused)

        recorder.didUpdate(locations: [
            location(x: 8, seconds: 20, speed: 2),
            location(x: 12, seconds: 23, speed: 2)
        ])

        #expect(recorder.state == .recording)
        #expect(recorder.startedAt == firstRebase)
        #expect(recorder.startedAt == base.addingTimeInterval(3))
    }
}
```

- [ ] **2. Run it and verify RED.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected failure:

```text
error: extra argument 'armed' in call
** TEST FAILED **
```

- [ ] **3. Write the minimal implementation.** Add this observable session flag beside `autoStarted`:

```swift
    /// True only until the first armed auto-pause-to-recording transition.
    /// This is the one-shot guard that prevents later auto-pause cycles from
    /// rebasing `startedAt`.
    private(set) var isArmed = false
```

Replace `start` with this complete signature and body:

```swift
    func start(activity: ActivityType,
               resumeFrom checkpoint: SessionCheckpoint? = nil,
               backdatedTo walkBeganAt: Date? = nil,
               autoStarted: Bool = false,
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
            pendingGap = !checkpoint.route.isEmpty
        } else {
            startedAt = walkBeganAt ?? now
            movingSeconds = walkBeganAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
            distanceMeters = 0
            route = []
            splitSeconds = []
            lastSplitMovingSeconds = movingSeconds
            pendingGap = false
        }
        lastKeptLocation = nil
        lastCheckpointAt = nil
        autoPause = AutoPauseDetector(activity: activity, startPaused: self.isArmed)
        timeAnchor = clock()
        state = self.isArmed ? .autoPaused : .recording
        reducedAccuracy = provider.accuracyAuthorization == .reducedAccuracy
        if reducedAccuracy {
            provider.requestTemporaryFullAccuracy(purposeKey: Self.fullAccuracyPurposeKey)
        }
        provider.startUpdates()
    }
```

Replace ingest step 3 with:

```swift
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
                }
            }
            state = paused ? .autoPaused : .recording
        }
```

Add `isArmed = false` to `reset()`. No other ingest change is required: step 1 only calls `advanceTimer` while `.recording`, so the clock remains frozen before the first transition, and step 3 resets `timeAnchor` at the un-freeze sample.

- [ ] **4. Run the complete suite and verify GREEN.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected output:

```text
** TEST SUCCEEDED **
```

- [ ] **5. Commit.**

```bash
git add Runner/Core/Recording/WorkoutRecorder.swift RunnerTests/ArmedWorkoutRecorderTests.swift
git commit -m "feat: arm recorder with one-time start rebase"
```

### Task 3: Track the last moving sample and trim every manual finish

**Files:**
- Modify: `Runner/Core/Recording/WorkoutRecorder.swift`
- Modify: `Runner/Core/Recording/AutoWalkCoordinator.swift`
- Modify: `Runner/Features/Record/RecordView.swift`
- Modify: `RunnerTests/WorkoutRecorderTests.swift`
- Create: `RunnerTests/WorkoutTailTrimTests.swift`

**Interfaces**

- **Consumes:** `WorkoutRecorder.finish(endingAt:)`, ingest steps 3–5, and `RecordView`'s GO and `SlideToFinish` closures.
- **Produces:** `private(set) var lastMovingAt: Date?` and `func finish(endingAt end: Date? = nil) -> RecordedWorkout?`.

- [ ] **1. Write the failing test.** Create `RunnerTests/WorkoutTailTrimTests.swift`:

```swift
import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
struct WorkoutTailTrimTests {
    private let base = Date().addingTimeInterval(-2)

    private func location(x: Double, seconds: TimeInterval,
                          speed: Double) -> CLLocation {
        let longitude = -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180))
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 45.5, longitude: longitude),
            altitude: 30,
            horizontalAccuracy: 5,
            verticalAccuracy: 10,
            course: 90,
            speed: speed,
            timestamp: base.addingTimeInterval(seconds)
        )
    }

    private func makeRecorder() -> WorkoutRecorder {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tail-trim-\(UUID().uuidString)")
        return WorkoutRecorder(
            provider: FakeLocationProvider(),
            checkpoints: CheckpointStore(directory: directory),
            clock: { base }
        )
    }

    @Test func lastMovingAtTracksTheLastAcceptedRecordingSample() throws {
        let recorder = makeRecorder()
        recorder.start(activity: .run, armed: true)
        recorder.didUpdate(locations: [
            location(x: 0, seconds: 0, speed: 2),
            location(x: 5, seconds: 3, speed: 2),
            location(x: 15, seconds: 7, speed: 2)
        ])
        #expect(recorder.lastMovingAt == base.addingTimeInterval(7))

        recorder.didUpdate(locations: [
            location(x: 15.2, seconds: 9, speed: 0),
            location(x: 15.2, seconds: 19, speed: 0)
        ])
        #expect(recorder.lastMovingAt == base.addingTimeInterval(7))

        let workout = try #require(
            recorder.finish(endingAt: recorder.lastMovingAt)
        )
        #expect(workout.end == base.addingTimeInterval(7))
        #expect(workout.start == base.addingTimeInterval(3))
        #expect(workout.movingSeconds == 4)
    }

    @Test func finishingAnArmedSessionThatNeverMovedProducesNoWorkout() {
        let recorder = makeRecorder()
        recorder.start(activity: .run, armed: true)

        #expect(recorder.finish(endingAt: recorder.lastMovingAt) == nil)
        #expect(recorder.state == .idle)
    }
}
```

- [ ] **2. Run it and verify RED.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected failure:

```text
error: value of type 'WorkoutRecorder' has no member 'lastMovingAt'
** TEST FAILED **
```

- [ ] **3. Write the minimal implementation.** Add beside `startedAt`:

```swift
    private(set) var lastMovingAt: Date?
```

In `start`, set `lastMovingAt = checkpoint?.route.last?.t` after the checkpoint/new-session branch. In ingest, replace step 4 with this exact block; updating only after acceptance prevents stationary sub-three-metre noise from moving the trim point:

```swift
        // 4. Accept or reject the sample.
        let decision = LocationFilter.evaluate(candidate: location,
                                               lastKept: lastKeptLocation,
                                               now: Date())
        guard decision.accepted, state == .recording else { return }
        lastMovingAt = location.timestamp
```

Replace `finish` with:

```swift
    func finish(endingAt end: Date? = nil) -> RecordedWorkout? {
        guard !isArmed else {
            discard()
            return nil
        }
        provider.stopUpdates()
        if state == .recording { advanceTimer(to: end ?? clock()) }
        let start = startedAt ?? clock()
        let finishedAt = end ?? clock()
        let elapsed = max(0, finishedAt.timeIntervalSince(start))
        let workout = RecordedWorkout(type: activity,
                                      start: start,
                                      end: finishedAt,
                                      movingSeconds: min(movingSeconds, elapsed),
                                      distanceMeters: distanceMeters,
                                      route: route,
                                      splitSeconds: splitSeconds,
                                      autoStarted: autoStarted)
        saveCheckpoint(at: clock())
        reset()
        return workout
    }
```

Add `lastMovingAt = nil` to `reset()`.

Replace `AutoWalkCoordinator.autoStop(lastWalkingAt:)`'s finish line with this complete guard:

```swift
        guard var workout = recorder.finish(endingAt: lastWalkingAt) else {
            recorder.discard()
            return
        }
```

In `WorkoutRecorderTests.checkpointsPeriodicallyAndFinishKeepsCheckpoint`, change the signature and finish line to:

```swift
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
```

In `RecordView`, make the GO and finish closures exactly:

```swift
            Button {
                recorder.start(activity: selectedActivity, armed: true)
            } label: {
```

```swift
                SlideToFinish {
                    finished = recorder.finish(endingAt: recorder.lastMovingAt)
                }
```

Render the ready state before the existing auto-pause label:

```swift
            if recorder.isArmed {
                Label(String(localized: "Ready — start moving"),
                      systemImage: "figure.run")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.rLime)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.rLime.opacity(0.15)))
            } else if recorder.state == .autoPaused {
                Label(String(localized: "Auto-paused"), systemImage: "pause.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.rOrange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.rOrange.opacity(0.15)))
            }
```

Add `.disabled(recorder.isArmed)` to the circular manual pause button so a ready session cannot bypass the detector through `resumeManually()`.

- [ ] **4. Run the complete suite and verify GREEN.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected output:

```text
** TEST SUCCEEDED **
```

- [ ] **5. Commit.**

```bash
git add Runner/Core/Recording/WorkoutRecorder.swift Runner/Core/Recording/AutoWalkCoordinator.swift Runner/Features/Record/RecordView.swift RunnerTests/WorkoutRecorderTests.swift RunnerTests/WorkoutTailTrimTests.swift
git commit -m "feat: trim manual workouts at last movement"
```

### Task 4: Cancel a never-started armed session after ten minutes

**Files:**
- Modify: `Runner/Core/Recording/WorkoutRecorder.swift`
- Create: `RunnerTests/ArmedTimeoutTests.swift`

**Interfaces**

- **Consumes:** `func discard()`, `private(set) var isArmed: Bool`, and `clock: () -> Date`.
- **Produces:** `init(provider: LocationProviding, checkpoints: CheckpointStore = CheckpointStore(), checkpointInterval: TimeInterval = 30, armedTimeout: Duration = .seconds(600), clock: @escaping () -> Date = { Date() })`.

- [ ] **1. Write the failing test.** Create `RunnerTests/ArmedTimeoutTests.swift`:

```swift
import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
struct ArmedTimeoutTests {
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
        try? await Task.sleep(for: .milliseconds(60))

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
        try? await Task.sleep(for: .milliseconds(80))

        #expect(recorder.state == .recording)
        #expect(!recorder.isArmed)
    }
}
```

- [ ] **2. Run it and verify RED.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected failure:

```text
error: extra argument 'armedTimeout' in call
** TEST FAILED **
```

- [ ] **3. Write the minimal implementation.** Add:

```swift
    private let armedTimeout: Duration
    private var armedTimeoutTask: Task<Void, Never>?
```

Replace the initializer with:

```swift
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
```

At the end of `start`, after `provider.startUpdates()`, add:

```swift
        armedTimeoutTask?.cancel()
        if isArmed {
            let timeout = armedTimeout
            armedTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self, self.isArmed else { return }
                self.discard()
            }
        }
```

When the first armed transition clears `isArmed`, immediately add:

```swift
                    armedTimeoutTask?.cancel()
                    armedTimeoutTask = nil
```

At the top of `reset()`, add:

```swift
        armedTimeoutTask?.cancel()
        armedTimeoutTask = nil
```

- [ ] **4. Run the complete suite and verify GREEN.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected output:

```text
** TEST SUCCEEDED **
```

- [ ] **5. Commit.**

```bash
git add Runner/Core/Recording/WorkoutRecorder.swift RunnerTests/ArmedTimeoutTests.swift
git commit -m "feat: cancel stale armed recordings"
```

## Phase 2 — Spoken State Changes

### Task 5: Add the announcement interface and ducked speech implementation

**Files:**
- Create: `Runner/Core/Recording/RunAnnouncer.swift`
- Create: `RunnerTests/RunAnnouncerTests.swift`
- Modify: `Runner/Resources/Localizable.xcstrings`
- Modify: `project.yml`
- Modify: `Runner/Info.plist`

**Interfaces**

- **Consumes:** AVFoundation `AVAudioSession` and `AVSpeechSynthesizer`.
- **Produces:** `enum RunAnnouncement`, `@MainActor protocol Announcing: Sendable`, `RunAnnouncer.init(sink:)`, `func announce(_ event: RunAnnouncement)`, and `SilentAnnouncer`.

- [ ] **1. Write the failing test.** Create `RunnerTests/RunAnnouncerTests.swift`:

```swift
import Testing
@testable import Runner

@MainActor
struct RunAnnouncerTests {
    private final class Spoken: @unchecked Sendable {
        var values: [String] = []
    }

    @Test func emitsTheExactLocalizedTextWithoutPlayingAudio() {
        let spoken = Spoken()
        let announcer = RunAnnouncer { spoken.values.append($0) }

        announcer.announce(.runStarted)
        announcer.announce(.paused)
        announcer.announce(.resumed)
        announcer.announce(.runSaved)
        announcer.announce(.runCancelled)
        announcer.announce(.locationDenied)

        #expect(spoken.values == [
            String(localized: "Run started"),
            String(localized: "Paused"),
            String(localized: "Resumed"),
            String(localized: "Run saved"),
            String(localized: "Run cancelled"),
            String(localized: "Location access is required")
        ])
    }
}
```

- [ ] **2. Run it and verify RED.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected failure:

```text
error: cannot find 'RunAnnouncer' in scope
** TEST FAILED **
```

- [ ] **3. Write the minimal implementation.** Create `RunAnnouncer.swift`:

```swift
import Foundation
import AVFoundation

enum RunAnnouncement: Equatable, Sendable {
    case runStarted
    case paused
    case resumed
    case runSaved
    case runCancelled
    case locationDenied

    var localizedText: String {
        switch self {
        case .runStarted: String(localized: "Run started")
        case .paused: String(localized: "Paused")
        case .resumed: String(localized: "Resumed")
        case .runSaved: String(localized: "Run saved")
        case .runCancelled: String(localized: "Run cancelled")
        case .locationDenied: String(localized: "Location access is required")
        }
    }
}

@MainActor
protocol Announcing: Sendable {
    func announce(_ event: RunAnnouncement)
}

@MainActor
final class RunAnnouncer: Announcing {
    private let synthesizer = AVSpeechSynthesizer()
    private let sink: (@MainActor @Sendable (String) -> Void)?

    init(sink: (@MainActor @Sendable (String) -> Void)? = nil) {
        self.sink = sink
    }

    func announce(_ event: RunAnnouncement) {
        let text = event.localizedText
        if let sink {
            sink(text)
            return
        }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier)
        synthesizer.speak(utterance)
    }
}

@MainActor
struct SilentAnnouncer: Announcing {
    func announce(_ event: RunAnnouncement) {}
}
```

In `project.yml`, change:

```yaml
        UIBackgroundModes: [location, audio]
```

In `Runner/Info.plist`, replace the background-modes array with:

```xml
	<key>UIBackgroundModes</key>
	<array>
		<string>location</string>
		<string>audio</string>
	</array>
```

Edit `Localizable.xcstrings` textually, inserting these complete entries in alphabetical position. Do not run a JSON formatter or serializer:

```json
    "Location access is required": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "L’accès à la localisation est requis"
          }
        }
      }
    },
    "Paused": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "En pause"
          }
        }
      }
    },
    "Ready — start moving": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Prêt — commencez à bouger"
          }
        }
      }
    },
    "Resumed": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Reprise"
          }
        }
      }
    },
    "Run cancelled": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Course annulée"
          }
        }
      }
    },
    "Run saved": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Course enregistrée"
          }
        }
      }
    },
    "Run started": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Course commencée"
          }
        }
      }
    },
```

Regenerate immediately because `project.yml` changed:

```bash
xcodegen generate
```

- [ ] **4. Run the complete suite and verify GREEN.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected output:

```text
** TEST SUCCEEDED **
```

- [ ] **5. Commit.**

```bash
git add Runner/Core/Recording/RunAnnouncer.swift RunnerTests/RunAnnouncerTests.swift Runner/Resources/Localizable.xcstrings project.yml Runner/Info.plist
git commit -m "feat: add ducked spoken run feedback"
```

### Task 6: Announce recorder transitions once and keep auto-walk silent

**Files:**
- Modify: `Runner/Core/Recording/WorkoutRecorder.swift`
- Modify: `RunnerTests/AutoWalkCoordinatorTests.swift`
- Create: `RunnerTests/RecorderAnnouncementTests.swift`

**Interfaces**

- **Consumes:** `Announcing.announce(_:)`, `WorkoutRecorder.isArmed`, manual pause/resume, auto-pause ingest transitions, authorization callbacks, and armed timeout.
- **Produces:** `init(provider: LocationProviding, checkpoints: CheckpointStore = CheckpointStore(), checkpointInterval: TimeInterval = 30, armedTimeout: Duration = .seconds(600), clock: @escaping () -> Date = { Date() }, announcer: any Announcing = SilentAnnouncer())` and exact once-only transition announcements.

- [ ] **1. Write the failing test.** Create `RunnerTests/RecorderAnnouncementTests.swift`:

```swift
import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
struct RecorderAnnouncementTests {
    private final class AnnouncementSpy: Announcing {
        var events: [RunAnnouncement] = []
        func announce(_ event: RunAnnouncement) {
            events.append(event)
        }
    }

    private let base = Date().addingTimeInterval(-2)

    private func location(x: Double, seconds: TimeInterval,
                          speed: Double) -> CLLocation {
        let longitude = -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180))
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 45.5, longitude: longitude),
            altitude: 30,
            horizontalAccuracy: 5,
            verticalAccuracy: 10,
            course: 90,
            speed: speed,
            timestamp: base.addingTimeInterval(seconds)
        )
    }

    @Test func fullRecorderSequenceAnnouncesEachTransitionOnce() {
        let spy = AnnouncementSpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            announcer: spy,
            clock: { base }
        )

        recorder.start(activity: .run, armed: true)
        recorder.didUpdate(locations: [
            location(x: 0, seconds: 0, speed: 2),
            location(x: 5, seconds: 3, speed: 2),
            location(x: 5, seconds: 4, speed: 0),
            location(x: 5, seconds: 14, speed: 0),
            location(x: 10, seconds: 20, speed: 2),
            location(x: 15, seconds: 23, speed: 2)
        ])
        recorder.pauseManually()
        recorder.pauseManually()
        recorder.resumeManually()
        recorder.resumeManually()

        #expect(spy.events == [
            .runStarted,
            .paused,
            .resumed,
            .paused,
            .resumed
        ])
    }

    @Test func deniedAuthorizationIsAnnouncedOnce() {
        let spy = AnnouncementSpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            announcer: spy
        )
        recorder.start(activity: .run, armed: true)

        recorder.didChangeAuthorization(.denied)
        recorder.didChangeAuthorization(.denied)

        #expect(spy.events == [.locationDenied])
    }

    @Test func armedTimeoutAnnouncesCancellationOnce() async {
        let spy = AnnouncementSpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            armedTimeout: .milliseconds(20),
            announcer: spy
        )
        recorder.start(activity: .run, armed: true)

        try? await Task.sleep(for: .milliseconds(60))

        #expect(spy.events == [.runCancelled])
    }
}
```

Also add this complete test and spy inside `AutoWalkCoordinatorTests`:

```swift
    private final class AnnouncementSpy: Announcing {
        var events: [RunAnnouncement] = []
        func announce(_ event: RunAnnouncement) {
            events.append(event)
        }
    }

    @Test func autoWalkStaysSilent() async {
        let motion = FakeMotionActivityProvider()
        let location = FakeLocationProvider()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autowalk-silent-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(directory: directory)
        let announcements = AnnouncementSpy()
        let recorder = WorkoutRecorder(
            provider: location,
            checkpoints: checkpoints,
            clock: { self.now },
            announcer: announcements
        )
        let coordinator = AutoWalkCoordinator(
            motion: motion,
            recorder: recorder,
            health: FakeHealthStore(),
            checkpoints: checkpoints,
            clock: { self.now },
            canAutoStart: { true },
            save: { _ in }
        )

        await coordinator.ingest(walking(-300))
        await coordinator.ingest(walking(0))

        #expect(recorder.state == .recording)
        #expect(announcements.events.isEmpty)
    }
```

- [ ] **2. Run it and verify RED.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected failure:

```text
error: extra argument 'announcer' in call
** TEST FAILED **
```

- [ ] **3. Write the minimal implementation.** Add:

```swift
    private let announcer: any Announcing
    private var didAnnounceLocationDenied = false
```

Replace the current initializer with:

```swift
    init(provider: LocationProviding,
         checkpoints: CheckpointStore = CheckpointStore(),
         checkpointInterval: TimeInterval = 30,
         armedTimeout: Duration = .seconds(600),
         clock: @escaping () -> Date = { Date() },
         announcer: any Announcing = SilentAnnouncer()) {
        self.provider = provider
        self.checkpoints = checkpoints
        self.checkpointInterval = checkpointInterval
        self.armedTimeout = armedTimeout
        self.clock = clock
        self.announcer = announcer
        provider.delegate = self
    }
```

In the armed resume block, capture `wasArmed` before clearing it and announce only for a manual session:

```swift
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
```

Replace manual pause/resume with:

```swift
    func pauseManually() {
        guard !isArmed, state == .recording || state == .autoPaused else { return }
        if state == .recording { advanceTimer(to: clock()) }
        state = .manuallyPaused
        saveCheckpoint(at: clock())
        if !autoStarted { announcer.announce(.paused) }
    }

    func resumeManually() {
        guard state == .manuallyPaused else { return }
        autoPause = AutoPauseDetector(activity: activity)
        lastKeptLocation = nil
        pendingGap = !route.isEmpty
        timeAnchor = clock()
        state = .recording
        if !autoStarted { announcer.announce(.resumed) }
    }
```

In the armed-timeout task, announce before discard:

```swift
                self.announcer.announce(.runCancelled)
                self.discard()
```

Replace `didChangeAuthorization` with:

```swift
    func didChangeAuthorization(_ status: CLAuthorizationStatus) {
        authorizationDenied = (status == .denied || status == .restricted)
        reducedAccuracy = provider.accuracyAuthorization == .reducedAccuracy
        if authorizationDenied, state != .idle, !autoStarted, !didAnnounceLocationDenied {
            didAnnounceLocationDenied = true
            announcer.announce(.locationDenied)
        }
    }
```

Set `didAnnounceLocationDenied = false` in `start` and `reset`.

- [ ] **4. Run the complete suite and verify GREEN.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected output:

```text
** TEST SUCCEEDED **
```

- [ ] **5. Commit.**

```bash
git add Runner/Core/Recording/WorkoutRecorder.swift RunnerTests/RecorderAnnouncementTests.swift RunnerTests/AutoWalkCoordinatorTests.swift
git commit -m "feat: announce run state transitions"
```

## Phase 3 — Live Activity

### Task 7: Define pure Live Activity state, presentation protocol, and update policy

**Files:**
- Create: `Runner/Core/Recording/RunAttributes.swift`
- Create: `Runner/Core/Recording/LiveActivityPresenting.swift`
- Create: `RunnerTests/RunActivityStateTests.swift`

**Interfaces**

- **Consumes:** recorder state, moving time, distance, pace, location-warning state, and Foundation dates.
- **Produces:** `RunAttributes`, `RunActivitySnapshot`, `RunActivityStatus`, `func begin(_ snapshot: RunActivitySnapshot)`, `func update(_ snapshot: RunActivitySnapshot)`, `func end(_ snapshot: RunActivitySnapshot)`, `SilentLiveActivityPresenter`, and `static func shouldUpdate(previous: RunActivitySnapshot?, next: RunActivitySnapshot, lastUpdateAt: Date?, now: Date) -> Bool`.

- [ ] **1. Write the failing test.** Create `RunnerTests/RunActivityStateTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

struct RunActivityStateTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func snapshot(status: RunActivityStatus,
                          seconds: Double = 0) -> RunActivitySnapshot {
        RunActivitySnapshot(
            status: status,
            startedAt: base,
            movingSeconds: seconds,
            distanceMeters: 0,
            paceSecondsPerKm: nil,
            reducedAccuracy: false,
            message: nil
        )
    }

    @Test func stateChangesUpdateImmediately() {
        #expect(RunActivityUpdatePolicy.shouldUpdate(
            previous: snapshot(status: .ready),
            next: snapshot(status: .recording),
            lastUpdateAt: base,
            now: base.addingTimeInterval(1)
        ))
    }

    @Test func statsAreThrottledUntilFiveSecondsHaveElapsed() {
        #expect(!RunActivityUpdatePolicy.shouldUpdate(
            previous: snapshot(status: .recording),
            next: snapshot(status: .recording, seconds: 4),
            lastUpdateAt: base,
            now: base.addingTimeInterval(4)
        ))
        #expect(RunActivityUpdatePolicy.shouldUpdate(
            previous: snapshot(status: .recording),
            next: snapshot(status: .recording, seconds: 5),
            lastUpdateAt: base,
            now: base.addingTimeInterval(5)
        ))
    }

    @Test func warningsUpdateImmediately() {
        let previous = snapshot(status: .recording)
        let next = RunActivitySnapshot(
            status: .recording,
            startedAt: base,
            movingSeconds: 1,
            distanceMeters: 0,
            paceSecondsPerKm: nil,
            reducedAccuracy: true,
            message: String(localized: "Precise Location is off")
        )
        #expect(RunActivityUpdatePolicy.shouldUpdate(
            previous: previous,
            next: next,
            lastUpdateAt: base,
            now: base.addingTimeInterval(1)
        ))
    }
}
```

- [ ] **2. Run it and verify RED.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected failure:

```text
error: cannot find 'RunActivitySnapshot' in scope
** TEST FAILED **
```

- [ ] **3. Write the minimal implementation.** Create `RunAttributes.swift`:

```swift
import Foundation
import ActivityKit

enum RunActivityStatus: String, Codable, Hashable, Sendable {
    case ready
    case recording
    case paused
    case finished
    case error
}

struct RunActivitySnapshot: Codable, Hashable, Sendable {
    let status: RunActivityStatus
    let startedAt: Date
    let movingSeconds: Double
    let distanceMeters: Double
    let paceSecondsPerKm: Double?
    let reducedAccuracy: Bool
    let message: String?
}

struct RunAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        let snapshot: RunActivitySnapshot
    }

    let sessionID: UUID
}
```

Create `LiveActivityPresenting.swift`:

```swift
import Foundation

@MainActor
protocol LiveActivityPresenting: Sendable {
    func begin(_ snapshot: RunActivitySnapshot)
    func update(_ snapshot: RunActivitySnapshot)
    func end(_ snapshot: RunActivitySnapshot)
}

@MainActor
struct SilentLiveActivityPresenter: LiveActivityPresenting {
    func begin(_ snapshot: RunActivitySnapshot) {}
    func update(_ snapshot: RunActivitySnapshot) {}
    func end(_ snapshot: RunActivitySnapshot) {}
}

enum RunActivityUpdatePolicy {
    static let minimumInterval: TimeInterval = 5

    static func shouldUpdate(previous: RunActivitySnapshot?,
                             next: RunActivitySnapshot,
                             lastUpdateAt: Date?,
                             now: Date) -> Bool {
        guard let previous, let lastUpdateAt else { return true }
        if previous.status != next.status ||
            previous.reducedAccuracy != next.reducedAccuracy ||
            previous.message != next.message {
            return true
        }
        return now.timeIntervalSince(lastUpdateAt) >= minimumInterval
    }
}
```

- [ ] **4. Run the complete suite and verify GREEN.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected output:

```text
** TEST SUCCEEDED **
```

- [ ] **5. Commit.**

```bash
git add Runner/Core/Recording/RunAttributes.swift Runner/Core/Recording/LiveActivityPresenting.swift RunnerTests/RunActivityStateTests.swift
git commit -m "feat: define live run presentation state"
```

### Task 8: Implement the ActivityKit lifecycle and connect manual runs only

**Files:**
- Create: `Runner/Core/Recording/LiveActivityController.swift`
- Modify: `Runner/Core/Recording/WorkoutRecorder.swift`
- Modify: `Runner/App/AppModel.swift`
- Modify: `Runner/Features/Record/RecordView.swift`
- Modify: `RunnerTests/AutoWalkCoordinatorTests.swift`
- Create: `RunnerTests/LiveActivityWiringTests.swift`

**Interfaces**

- **Consumes:** `LiveActivityPresenting`, `RunAttributes`, `RunActivityUpdatePolicy`, recorder transitions, and `autoStarted`.
- **Produces:** `LiveActivityController.init(clock: @escaping () -> Date = { Date() })`, recorder `func completeSave()`, and `init(provider: LocationProviding, checkpoints: CheckpointStore = CheckpointStore(), checkpointInterval: TimeInterval = 30, armedTimeout: Duration = .seconds(600), clock: @escaping () -> Date = { Date() }, announcer: any Announcing = SilentAnnouncer(), liveActivity: any LiveActivityPresenting = SilentLiveActivityPresenter())`.

- [ ] **1. Write the failing test.** Create `RunnerTests/LiveActivityWiringTests.swift`:

```swift
import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
struct LiveActivityWiringTests {
    final class LiveActivitySpy: LiveActivityPresenting {
        var began: [RunActivitySnapshot] = []
        var updated: [RunActivitySnapshot] = []
        var ended: [RunActivitySnapshot] = []
        func begin(_ snapshot: RunActivitySnapshot) { began.append(snapshot) }
        func update(_ snapshot: RunActivitySnapshot) { updated.append(snapshot) }
        func end(_ snapshot: RunActivitySnapshot) { ended.append(snapshot) }
    }

    private let base = Date().addingTimeInterval(-2)

    private func location(x: Double, seconds: TimeInterval,
                          speed: Double) -> CLLocation {
        let longitude = -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180))
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 45.5, longitude: longitude),
            altitude: 30,
            horizontalAccuracy: 5,
            verticalAccuracy: 10,
            course: 90,
            speed: speed,
            timestamp: base.addingTimeInterval(seconds)
        )
    }

    @Test func manualRunBeginsReadyAndEndsOnlyAfterSaveCompletes() throws {
        let live = LiveActivitySpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            clock: { base },
            liveActivity: live
        )

        recorder.start(activity: .run, armed: true)
        #expect(live.began.map(\.status) == [.ready])

        recorder.didUpdate(locations: [
            location(x: 0, seconds: 0, speed: 2),
            location(x: 5, seconds: 3, speed: 2)
        ])
        #expect(live.updated.contains { $0.status == .recording })

        _ = try #require(recorder.finish(endingAt: recorder.lastMovingAt))
        #expect(live.ended.isEmpty)

        recorder.completeSave()
        #expect(live.ended.map(\.status) == [.finished])
    }

    @Test func manualWalkDoesNotOpenALiveActivity() {
        let live = LiveActivitySpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            liveActivity: live
        )
        recorder.start(activity: .walk, armed: true)
        #expect(live.began.isEmpty)
    }

    @Test func armedTimeoutEndsTheLiveActivity() async {
        let live = LiveActivitySpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            armedTimeout: .milliseconds(20),
            liveActivity: live
        )
        recorder.start(activity: .run, armed: true)

        try? await Task.sleep(for: .milliseconds(60))

        #expect(live.ended.map(\.status) == [.finished])
    }
}
```

Extend the `AutoWalkCoordinatorTests.autoWalkStaysSilent` test from Task 6 by adding this complete spy:

```swift
    private final class LiveActivitySpy: LiveActivityPresenting {
        var beginCount = 0
        func begin(_ snapshot: RunActivitySnapshot) { beginCount += 1 }
        func update(_ snapshot: RunActivitySnapshot) {}
        func end(_ snapshot: RunActivitySnapshot) {}
    }
```

Create `let liveActivity = LiveActivitySpy()`, pass `liveActivity: liveActivity` to that test's recorder, and add:

```swift
        #expect(liveActivity.beginCount == 0)
```

- [ ] **2. Run it and verify RED.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected failure:

```text
error: extra argument 'liveActivity' in call
** TEST FAILED **
```

- [ ] **3. Write the minimal implementation.** Create `LiveActivityController.swift`:

```swift
import Foundation
import ActivityKit

@MainActor
final class LiveActivityController: LiveActivityPresenting {
    private var activity: Activity<RunAttributes>?
    private var previous: RunActivitySnapshot?
    private var lastUpdateAt: Date?
    private let clock: () -> Date

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    func begin(_ snapshot: RunActivitySnapshot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              activity == nil else { return }
        let content = ActivityContent(
            state: RunAttributes.ContentState(snapshot: snapshot),
            staleDate: nil
        )
        activity = try? Activity.request(
            attributes: RunAttributes(sessionID: UUID()),
            content: content,
            pushType: nil
        )
        previous = snapshot
        lastUpdateAt = clock()
    }

    func update(_ snapshot: RunActivitySnapshot) {
        let now = clock()
        guard let activity,
              RunActivityUpdatePolicy.shouldUpdate(
                previous: previous,
                next: snapshot,
                lastUpdateAt: lastUpdateAt,
                now: now
              ) else { return }
        previous = snapshot
        lastUpdateAt = now
        Task {
            await activity.update(ActivityContent(
                state: RunAttributes.ContentState(snapshot: snapshot),
                staleDate: nil
            ))
        }
    }

    func end(_ snapshot: RunActivitySnapshot) {
        guard let activity else { return }
        self.activity = nil
        previous = nil
        lastUpdateAt = nil
        Task {
            await activity.end(
                ActivityContent(
                    state: RunAttributes.ContentState(snapshot: snapshot),
                    staleDate: nil
                ),
                dismissalPolicy: .immediate
            )
        }
    }
}
```

Add these recorder properties:

```swift
    private let liveActivity: any LiveActivityPresenting
    private var lastFinishedSnapshot: RunActivitySnapshot?
```

Extend the initializer after `announcer`:

```swift
         announcer: any Announcing = SilentAnnouncer(),
         liveActivity: any LiveActivityPresenting = SilentLiveActivityPresenter()) {
```

and assign:

```swift
        self.liveActivity = liveActivity
```

Add:

```swift
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
                ? String(localized: "Location access is required")
                : reducedAccuracy
                    ? String(localized: "Precise Location is off")
                    : nil
        )
    }

    private var presentsLiveActivity: Bool {
        activity == .run && !autoStarted
    }
```

At the end of `start`, before scheduling the timeout:

```swift
        if presentsLiveActivity {
            liveActivity.begin(liveSnapshot())
        }
```

After every state transition in ingest and after every accepted sample, call:

```swift
        if presentsLiveActivity {
            liveActivity.update(liveSnapshot())
        }
```

Call the same update at the end of `pauseManually`, `resumeManually`, and `didChangeAuthorization`.

Before `reset()` in `finish`, capture and publish the final snapshot:

```swift
        if presentsLiveActivity {
            let snapshot = liveSnapshot(status: .finished)
            lastFinishedSnapshot = snapshot
            liveActivity.update(snapshot)
        }
```

Add:

```swift
    func completeSave() {
        guard let snapshot = lastFinishedSnapshot else { return }
        announcer.announce(.runSaved)
        liveActivity.end(snapshot)
        lastFinishedSnapshot = nil
    }
```

In `discard`, end any manual run activity before reset:

```swift
        if presentsLiveActivity {
            liveActivity.end(liveSnapshot(status: .finished))
        } else if let lastFinishedSnapshot {
            liveActivity.end(lastFinishedSnapshot)
        }
        lastFinishedSnapshot = nil
```

In `RecordView.save(_:)`, after `model.checkpoints.clear()`, call `recorder.completeSave()`. In the summary discard closure, call `recorder.discard()` before clearing `finished`.

In `AppModel.live()`, construct the production recorder with the concrete implementations:

```swift
        let model = AppModel(
            store: store,
            health: HealthStore(),
            recorder: WorkoutRecorder(
                provider: SystemLocationProvider(),
                checkpoints: checkpoints,
                announcer: RunAnnouncer(),
                liveActivity: LiveActivityController()
            ),
            checkpoints: checkpoints
        )
```

- [ ] **4. Run the complete suite and verify GREEN.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected output:

```text
** TEST SUCCEEDED **
```

- [ ] **5. Commit.**

```bash
git add Runner/Core/Recording/LiveActivityController.swift Runner/Core/Recording/WorkoutRecorder.swift Runner/App/AppModel.swift Runner/Features/Record/RecordView.swift RunnerTests/LiveActivityWiringTests.swift RunnerTests/AutoWalkCoordinatorTests.swift
git commit -m "feat: connect manual runs to live activity lifecycle"
```

### Task 9: Add the RunnerWidgets target and Live Activity presentation

**Files:**
- Modify: `project.yml`
- Modify: `Runner/Info.plist`
- Modify: `Runner/Core/Recording/RunAttributes.swift`
- Modify: `Runner/Resources/Localizable.xcstrings`
- Create: `RunnerWidgets/RunnerWidgetsBundle.swift`
- Create: `RunnerWidgets/RunLiveActivity.swift`
- Create: `RunnerWidgets/WidgetIntentPlaceholders.swift`
- Create: `RunnerTests/RunnerWidgetsContractTests.swift`

**Interfaces**

- **Consumes:** `RunAttributes`, `RunActivitySnapshot`, `TogglePauseIntent`, and `FinishRunIntent`.
- **Produces:** `RunnerWidgets` app-extension target with bundle ID `com.farid.runner.widgets`, `NSSupportsLiveActivities: true`, and Lock Screen/Dynamic Island presentation.

The two placeholder intent types in the extension exist only so WidgetKit can compile the buttons. The matching app-target types in Phase 4 contain the real bodies. Both conform to `LiveActivityIntent`; never replace either side with plain `AppIntent`.

- [ ] **1. Write the failing test.** Create `RunnerTests/RunnerWidgetsContractTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

struct RunnerWidgetsContractTests {
    @Test func extensionContractHasStableIdentifiers() {
        #expect(RunnerWidgetContract.bundleIdentifier == "com.farid.runner.widgets")
        #expect(RunnerWidgetContract.extensionPointIdentifier ==
                "com.apple.widgetkit-extension")
    }

    @Test func contentStateRoundTripsForTheExtensionBoundary() throws {
        let expected = RunAttributes.ContentState(snapshot: RunActivitySnapshot(
            status: .paused,
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            movingSeconds: 321,
            distanceMeters: 1_234,
            paceSecondsPerKm: 260,
            reducedAccuracy: false,
            message: nil
        ))
        let data = try JSONEncoder().encode(expected)
        let decoded = try JSONDecoder().decode(
            RunAttributes.ContentState.self,
            from: data
        )
        #expect(decoded == expected)
    }
}
```

- [ ] **2. Run it and verify RED.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected failure:

```text
error: cannot find 'RunnerWidgetContract' in scope
** TEST FAILED **
```

- [ ] **3. Write the minimal implementation.** Append this target-neutral contract to `RunAttributes.swift`:

```swift
enum RunnerWidgetContract {
    static let bundleIdentifier = "com.farid.runner.widgets"
    static let extensionPointIdentifier = "com.apple.widgetkit-extension"
}
```

Create `WidgetIntentPlaceholders.swift`:

```swift
import AppIntents

struct TogglePauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or resume run"
    func perform() async throws -> some IntentResult { .result() }
}

struct FinishRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Finish run"
    func perform() async throws -> some IntentResult { .result() }
}
```

Create `RunLiveActivity.swift`:

```swift
import ActivityKit
import AppIntents
import Foundation
import SwiftUI
import WidgetKit

struct RunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunAttributes.self) { context in
            let snapshot = context.state.snapshot
            VStack(alignment: .leading, spacing: 10) {
                Text(title(for: snapshot))
                    .font(.headline)
                if let message = snapshot.message {
                    Text(message).font(.caption)
                }
                HStack {
                    stat(String(localized: "Time"), WidgetFormat.duration(snapshot.movingSeconds))
                    stat(String(localized: "Distance"), WidgetFormat.km(snapshot.distanceMeters))
                    stat(String(localized: "Pace"), WidgetFormat.pace(snapshot.paceSecondsPerKm))
                }
                if snapshot.status != .ready && snapshot.status != .finished {
                    HStack {
                        Button(intent: TogglePauseIntent()) {
                            Label(
                                snapshot.status == .paused
                                    ? String(localized: "Resume")
                                    : String(localized: "Pause"),
                                systemImage: snapshot.status == .paused
                                    ? "play.fill"
                                    : "pause.fill"
                            )
                        }
                        Button(intent: FinishRunIntent()) {
                            Label(String(localized: "Finish"),
                                  systemImage: "stop.fill")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .activityBackgroundTint(Color.black)
            .activitySystemActionForegroundColor(Color.green)
        } dynamicIsland: { context in
            let snapshot = context.state.snapshot
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(WidgetFormat.duration(snapshot.movingSeconds))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(WidgetFormat.km(snapshot.distanceMeters))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(title(for: snapshot))
                }
            } compactLeading: {
                Image(systemName: snapshot.status == .paused
                      ? "pause.fill" : "figure.run")
            } compactTrailing: {
                Text(WidgetFormat.duration(snapshot.movingSeconds))
            } minimal: {
                Image(systemName: "figure.run")
            }
        }
    }

    private func title(for snapshot: RunActivitySnapshot) -> String {
        switch snapshot.status {
        case .ready: String(localized: "Ready — start moving")
        case .recording: String(localized: "Run in progress")
        case .paused: String(localized: "Paused")
        case .finished: String(localized: "Run saved")
        case .error: snapshot.message ?? String(localized: "Location access is required")
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption2)
            Text(value).font(.caption.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum WidgetFormat {
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d",
                      total / 3600, (total % 3600) / 60, total % 60)
    }

    static func km(_ meters: Double) -> String {
        String(format: "%.2f km", meters / 1000)
    }

    static func pace(_ secondsPerKm: Double?) -> String {
        guard let secondsPerKm else { return "—" }
        let total = Int(secondsPerKm.rounded())
        return String(format: "%d:%02d /km", total / 60, total % 60)
    }
}
```

Create `RunnerWidgetsBundle.swift`:

```swift
import SwiftUI
import WidgetKit

@main
struct RunnerWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RunLiveActivity()
    }
}
```

Replace the complete `targets:` section in `project.yml` with:

```yaml
targets:
  Runner:
    type: application
    platform: iOS
    sources:
      - Runner
    dependencies:
      - target: RunnerWidgets
        embed: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.farid.runner
        PRODUCT_NAME: Runner
        CODE_SIGN_STYLE: Automatic
        CODE_SIGN_ENTITLEMENTS: Runner/Runner.entitlements
        TARGETED_DEVICE_FAMILY: "1"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        INFOPLIST_KEY_UIUserInterfaceStyle: Dark
        SWIFT_STRICT_CONCURRENCY: complete
    info:
      path: Runner/Info.plist
      properties:
        CFBundleDisplayName: Runner
        CFBundleShortVersionString: "1.9"
        CFBundleVersion: "11"
        CFBundleLocalizations: [en, fr]
        CFBundleDevelopmentRegion: en
        UILaunchScreen:
          UIColorName: LaunchBackground
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
        NSHealthShareUsageDescription: "Runner reads your daily steps and workouts to compute your daily points."
        NSHealthUpdateUsageDescription: "Runner saves your recorded runs, walks and rides to Apple Health so your data is permanently yours."
        NSLocationWhenInUseUsageDescription: "Runner uses your location to record your route while you run, walk or ride."
        NSLocationTemporaryUsageDescriptionDictionary:
          PreciseWorkout: "Precise location is needed to measure your distance and draw your route while recording a workout."
        NSMotionUsageDescription: "Runner uses motion activity to notice when you have been walking for a while, so it can record the walk for you."
        UIBackgroundModes: [location, audio]
        NSSupportsLiveActivities: true
        ITSAppUsesNonExemptEncryption: false
  RunnerWidgets:
    type: app-extension
    platform: iOS
    sources:
      - path: RunnerWidgets
      - path: Runner/Core/Recording/RunAttributes.swift
      - path: Runner/Resources/Localizable.xcstrings
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.farid.runner.widgets
        PRODUCT_NAME: RunnerWidgets
        CODE_SIGN_STYLE: Automatic
        TARGETED_DEVICE_FAMILY: "1"
        APPLICATION_EXTENSION_API_ONLY: YES
        SKIP_INSTALL: YES
        SWIFT_STRICT_CONCURRENCY: complete
    info:
      path: RunnerWidgets/Info.plist
      properties:
        CFBundleDisplayName: Runner
        CFBundleShortVersionString: "1.9"
        CFBundleVersion: "11"
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
        NSSupportsLiveActivities: true
  RunnerTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - RunnerTests
    dependencies:
      - target: Runner
    settings:
      base:
        GENERATE_INFOPLIST_FILE: true
        # XcodeGen sets TEST_HOST/BUNDLE_LOADER automatically for unit-test
        # targets that depend on an app target — do not set them by hand.
```

This explicitly compiles `Runner/Core/Recording/RunAttributes.swift` into both Runner (through the `Runner` directory source) and RunnerWidgets (through the second source path), and packages the existing string catalog in both bundles through the third path. No app implementation file is linked into the presentation-only extension.

Add this exact key to `Runner/Info.plist`:

```xml
	<key>NSSupportsLiveActivities</key>
	<true/>
```

Edit `Localizable.xcstrings` textually only and add these complete Phase 3 entries:

```json
    "Finish": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Terminer"
          }
        }
      }
    },
    "Finish run": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Terminer la course"
          }
        }
      }
    },
    "Pause or resume run": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Mettre la course en pause ou la reprendre"
          }
        }
      }
    },
    "Precise Location is off": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "La localisation précise est désactivée"
          }
        }
      }
    },
    "Run in progress": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Course en cours"
          }
        }
      }
    },
```

Generate the extension plist and project:

```bash
xcodegen generate
```

- [ ] **4. Run tests and the required build; verify GREEN.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -20
```

Expected final lines from each command:

```text
** TEST SUCCEEDED **
** BUILD SUCCEEDED **
```

- [ ] **5. Commit.**

```bash
git add project.yml Runner/Info.plist RunnerWidgets Runner/Core/Recording/RunAttributes.swift Runner/Resources/Localizable.xcstrings RunnerTests/RunnerWidgetsContractTests.swift
git commit -m "feat: add Runner live activity extension"
```

## Phase 4 — Start Run Control and Deferred Celebration

### Task 10: Spike locked-screen cold launch on a physical iPhone

**Files:**
- Modify: `Runner/App/AppModel.swift`
- Modify: `Runner/App/RunnerApp.swift`
- Create: `Runner/Core/Intents/StartRunIntent.swift`
- Create: `RunnerWidgets/StartRunControl.swift`
- Modify: `RunnerWidgets/RunnerWidgetsBundle.swift`
- Modify: `RunnerWidgets/WidgetIntentPlaceholders.swift`
- Create: `RunnerTests/StartRunIntentModelTests.swift`

**Interfaces**

- **Consumes:** `AppModel.pendingResume`, `showRecordSheet`, recorder state, `WorkoutRecorder.start(activity:armed:)`, and `LiveActivityIntent`.
- **Produces:** `AppModel.canAutoStart: Bool`, `func startRunFromIntent()`, app-target `StartRunIntent`, and the iOS 18 `StartRunControl`.

This task is the first task in Phase 4 because the only unresolved platform risk must be answered on-device before the remaining intent work. `LiveActivityIntent` is mandatory: it runs in the app process and may background-launch Runner; a plain `AppIntent` runs in the extension and cannot reach `AppModel`.

- [ ] **1. Write the failing test.** Create `RunnerTests/StartRunIntentModelTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

@MainActor
struct StartRunIntentModelTests {
    private func makeModel() throws -> AppModel {
        let store = try DataStore(inMemory: true)
        let health = FakeHealthStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("start-intent-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(directory: directory)
        return AppModel(
            store: store,
            health: health,
            recorder: WorkoutRecorder(
                provider: FakeLocationProvider(),
                checkpoints: checkpoints
            ),
            checkpoints: checkpoints
        )
    }

    @Test func startsOneArmedRunWhenRecorderIsAvailable() throws {
        let model = try makeModel()
        #expect(model.canAutoStart)

        model.startRunFromIntent()

        #expect(model.recorder.activity == .run)
        #expect(model.recorder.state == .autoPaused)
        #expect(model.recorder.isArmed)
        #expect(!model.canAutoStart)
    }

    @Test func doesNotHijackAnExistingSessionOrPendingResume() throws {
        let model = try makeModel()
        model.recorder.start(activity: .bike)
        model.startRunFromIntent()
        #expect(model.recorder.activity == .bike)

        model.recorder.discard()
        model.pendingResume = SessionCheckpoint(
            activity: .walk,
            startedAt: .now,
            movingSeconds: 10,
            distanceMeters: 20,
            route: [],
            splitSeconds: [],
            savedAt: .now
        )
        model.startRunFromIntent()
        #expect(model.recorder.state == .idle)
    }
}
```

- [ ] **2. Run it and verify RED.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected failure:

```text
error: value of type 'AppModel' has no member 'startRunFromIntent'
** TEST FAILED **
```

- [ ] **3. Write the minimal spike implementation.** In `AppModel`, add:

```swift
    var canAutoStart: Bool {
        pendingResume == nil &&
        !showRecordSheet &&
        recorder.state == .idle
    }

    func startRunFromIntent() {
        guard canAutoStart else { return }
        recorder.start(activity: .run, armed: true)
    }
```

Change `enableAutoWalk`'s closure to reuse the same rule:

```swift
            canAutoStart: { [weak self] in
                self?.canAutoStart == true
            },
```

Create app-target `StartRunIntent.swift`:

```swift
import AppIntents

struct StartRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Run"

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        model.startRunFromIntent()
        return .result()
    }
}
```

Replace `RunnerApp`'s stored model declaration with this initializer-backed registration:

```swift
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel.live()
        _model = State(initialValue: model)
        AppDependencyManager.shared.add(dependency: model)
    }
```

and add `import AppIntents`.

Add this type to `WidgetIntentPlaceholders.swift`:

```swift
struct StartRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Run"
    func perform() async throws -> some IntentResult { .result() }
}
```

Create `StartRunControl.swift`:

```swift
import AppIntents
import SwiftUI
import WidgetKit

struct StartRunControl: ControlWidget {
    static let kind = "com.farid.runner.start-run"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartRunIntent()) {
                Label(String(localized: "Start Run"),
                      systemImage: "figure.run")
            }
        }
        .displayName(String(localized: "Start Run"))
        .description(String(localized: "Arm a run without unlocking Runner."))
    }
}
```

Replace `RunnerWidgetsBundle` with:

```swift
import SwiftUI
import WidgetKit

@main
struct RunnerWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RunLiveActivity()
        StartRunControl()
    }
}
```

Run the suite, generate, deploy, and perform this physical acceptance test:

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
xcodegen generate
./scripts/deploy.sh
```

Acceptance sequence and expected evidence:

1. Force-quit Runner.
2. Lock the iPhone.
3. Wake the Lock Screen and tap **Start Run**.
4. Do not unlock or foreground the app.
5. Confirm the Live Activity reads **Ready — start moving**.
6. Walk/run for at least four seconds.
7. Confirm the Live Activity changes to live stats and the route starts in Runner.

Expected result: Runner background-launches from cold, location updates start, and the recorder leaves `.autoPaused` without an unlock.

If and only if the cold locked-screen test fails, add this exact fallback to the app-target `StartRunIntent`:

```swift
    static var openAppWhenRun: Bool { true }
```

Redeploy with `./scripts/deploy.sh` and repeat the seven steps. Expected fallback result: Face ID opens Runner, but one tap still arms the run without navigating or selecting an activity.

- [ ] **4. Re-run the suite and verify GREEN after the selected on-device branch.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected output:

```text
** TEST SUCCEEDED **
```

- [ ] **5. Commit the verified branch.**

```bash
git add Runner/App/AppModel.swift Runner/App/RunnerApp.swift Runner/Core/Intents/StartRunIntent.swift RunnerWidgets/StartRunControl.swift RunnerWidgets/RunnerWidgetsBundle.swift RunnerWidgets/WidgetIntentPlaceholders.swift RunnerTests/StartRunIntentModelTests.swift
git commit -m "feat: validate locked-screen run start"
```

### Task 11: Persist a pending finished workout safely

**Files:**
- Modify: `Runner/Core/Recording/WorkoutRecorder.swift`
- Create: `Runner/Core/Store/PendingCelebrationStore.swift`
- Create: `RunnerTests/PendingCelebrationStoreTests.swift`

**Interfaces**

- **Consumes:** `RecordedWorkout`, `RoutePoint: Codable`, and the `CheckpointStore` file-store pattern.
- **Produces:** `RecordedWorkout: Codable`, `PendingCelebrationStore.init(directory: URL? = nil)`, `func save(_ workout: RecordedWorkout) throws`, `func load() -> RecordedWorkout?`, and `func clear()`.

- [ ] **1. Write the failing test.** Create `RunnerTests/PendingCelebrationStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

struct PendingCelebrationStoreTests {
    private func makeStore() -> (PendingCelebrationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-celebration-\(UUID().uuidString)")
        return (PendingCelebrationStore(directory: directory), directory)
    }

    private var workout: RecordedWorkout {
        RecordedWorkout(
            type: .run,
            start: Date(timeIntervalSince1970: 1_750_000_000),
            end: Date(timeIntervalSince1970: 1_750_000_600),
            movingSeconds: 600,
            distanceMeters: 2_500,
            route: [],
            splitSeconds: [240, 245]
        )
    }

    @Test func roundTripsAndClears() throws {
        let (store, _) = makeStore()
        try store.save(workout)
        #expect(store.load() == workout)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test func corruptFileLoadsAsNil() throws {
        let (store, directory) = makeStore()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent("pending-celebration.json")
        )
        #expect(store.load() == nil)
    }
}
```

- [ ] **2. Run it and verify RED.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected failure:

```text
error: cannot find 'PendingCelebrationStore' in scope
** TEST FAILED **
```

- [ ] **3. Write the minimal implementation.** Change the workout declaration to:

```swift
struct RecordedWorkout: Codable, Equatable, Sendable {
```

Create `PendingCelebrationStore.swift`:

```swift
import Foundation

struct PendingCelebrationStore: Sendable {
    let directory: URL
    private var fileURL: URL {
        directory.appendingPathComponent("pending-celebration.json")
    }

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.directory = base.appendingPathComponent(
                "Runner",
                isDirectory: true
            )
        }
    }

    func save(_ workout: RecordedWorkout) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(workout).write(to: fileURL, options: .atomic)
    }

    func load() -> RecordedWorkout? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(RecordedWorkout.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
```

- [ ] **4. Run the complete suite and verify GREEN.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected output:

```text
** TEST SUCCEEDED **
```

- [ ] **5. Commit.**

```bash
git add Runner/Core/Recording/WorkoutRecorder.swift Runner/Core/Store/PendingCelebrationStore.swift RunnerTests/PendingCelebrationStoreTests.swift
git commit -m "feat: persist pending run celebrations"
```

### Task 12: Implement all intent-facing AppModel operations and immediate save

**Files:**
- Modify: `Runner/App/AppModel.swift`
- Create: `Runner/Core/Intents/TogglePauseIntent.swift`
- Create: `Runner/Core/Intents/FinishRunIntent.swift`
- Create: `RunnerTests/AppModelRunIntentTests.swift`

**Interfaces**

- **Consumes:** `SyncCoordinator.saveRecorded(_:)`, `PendingCelebrationStore`, `WorkoutRecorder.lastMovingAt`, `finish(endingAt:)`, `completeSave()`, manual pause/resume, and `canAutoStart`.
- **Produces:** `func togglePauseFromIntent()`, `func finishRunFromIntent() async`, `var pendingCelebration: RecordedWorkout?`, `func clearPendingCelebration()`, `TogglePauseIntent`, and `FinishRunIntent`.

- [ ] **1. Write the failing test.** Create `RunnerTests/AppModelRunIntentTests.swift`:

```swift
import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
struct AppModelRunIntentTests {
    private final class AnnouncementSpy: Announcing {
        var events: [RunAnnouncement] = []
        func announce(_ event: RunAnnouncement) { events.append(event) }
    }

    private func makeModel() throws -> (
        AppModel,
        PendingCelebrationStore,
        FakeHealthStore,
        AnnouncementSpy
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-intents-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(directory: directory)
        let pending = PendingCelebrationStore(directory: directory)
        let health = FakeHealthStore()
        let announcements = AnnouncementSpy()
        let model = AppModel(
            store: try DataStore(inMemory: true),
            health: health,
            recorder: WorkoutRecorder(
                provider: FakeLocationProvider(),
                checkpoints: checkpoints,
                announcer: announcements
            ),
            checkpoints: checkpoints,
            pendingCelebrations: pending
        )
        return (model, pending, health, announcements)
    }

    @Test func togglePausesAndResumesButDoesNothingWhileArmed() throws {
        let (model, _, _, _) = try makeModel()
        model.startRunFromIntent()
        model.togglePauseFromIntent()
        #expect(model.recorder.isArmed)
        #expect(model.recorder.state == .autoPaused)

        model.recorder.discard()
        model.recorder.start(activity: .run)
        model.togglePauseFromIntent()
        #expect(model.recorder.state == .manuallyPaused)
        model.togglePauseFromIntent()
        #expect(model.recorder.state == .recording)
    }

    @Test func finishTrimsSavesPersistsAndClearsCheckpoint() async throws {
        let (model, pending, _, announcements) = try makeModel()
        let end = Date()
        model.startRunFromIntent()
        model.recorder.didUpdate(locations: [
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 45.5, longitude: -73.6),
                altitude: 30,
                horizontalAccuracy: 5,
                verticalAccuracy: 10,
                course: 90,
                speed: 2,
                timestamp: end.addingTimeInterval(-3)
            ),
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 45.5, longitude: -73.5999),
                altitude: 30,
                horizontalAccuracy: 5,
                verticalAccuracy: 10,
                course: 90,
                speed: 2,
                timestamp: end
            )
        ])

        await model.finishRunFromIntent()

        #expect(model.recorder.state == .idle)
        #expect(model.checkpoints.load() == nil)
        #expect(pending.load()?.end == end)
        #expect(model.pendingCelebration?.end == end)
        #expect(try model.store.allWorkouts().count == 1)
        #expect(announcements.events == [.runStarted, .runSaved])
    }

    @Test func healthFailureStillSavesLocallyAndAnnouncesSaved() async throws {
        let (model, pending, health, announcements) = try makeModel()
        health.saveError = NSError(domain: "HealthKit", code: 1)
        let end = Date()
        model.recorder.start(activity: .run)
        model.recorder.didUpdate(locations: [
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 45.5, longitude: -73.6),
                altitude: 30,
                horizontalAccuracy: 5,
                verticalAccuracy: 10,
                course: 90,
                speed: 2,
                timestamp: end
            )
        ])

        await model.finishRunFromIntent()

        #expect(try model.store.allWorkouts().count == 1)
        #expect(pending.load() != nil)
        #expect(announcements.events == [.runSaved])
    }
}
```

- [ ] **2. Run it and verify RED.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected failure:

```text
error: extra argument 'pendingCelebrations' in call
** TEST FAILED **
```

- [ ] **3. Write the minimal implementation.** Add AppModel properties:

```swift
    let pendingCelebrations: PendingCelebrationStore
    var pendingCelebration: RecordedWorkout?
```

Replace the initializer signature and initial assignments with:

```swift
    init(store: DataStore,
         health: HealthStoring,
         recorder: WorkoutRecorder,
         checkpoints: CheckpointStore,
         pendingCelebrations: PendingCelebrationStore = PendingCelebrationStore()) {
        self.store = store
        self.health = health
        self.recorder = recorder
        self.checkpoints = checkpoints
        self.pendingCelebrations = pendingCelebrations
```

Keep the rest of the current initializer body unchanged. Add:

```swift
    func togglePauseFromIntent() {
        guard !recorder.isArmed else { return }
        if recorder.state == .manuallyPaused {
            recorder.resumeManually()
        } else {
            recorder.pauseManually()
        }
    }

    func finishRunFromIntent() async {
        guard let workout = recorder.finish(
            endingAt: recorder.lastMovingAt
        ) else { return }
        _ = await sync.saveRecorded(workout)
        checkpoints.clear()
        try? pendingCelebrations.save(workout)
        pendingCelebration = workout
        recorder.completeSave()
    }

    func clearPendingCelebration() {
        pendingCelebrations.clear()
        pendingCelebration = nil
    }
```

In both `onLaunch()` and `onForeground()`, load the file only when memory is empty:

```swift
        if pendingCelebration == nil {
            pendingCelebration = pendingCelebrations.load()
        }
```

Create `TogglePauseIntent.swift`:

```swift
import AppIntents

struct TogglePauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or resume run"
    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        model.togglePauseFromIntent()
        return .result()
    }
}
```

Create `FinishRunIntent.swift`:

```swift
import AppIntents

struct FinishRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Finish run"
    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        await model.finishRunFromIntent()
        return .result()
    }
}
```

These app-target intent bodies delegate directly to `AppModel`. Their same-named extension placeholders contain no logic and are never the intended execution path.

- [ ] **4. Run the complete suite and verify GREEN.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected output:

```text
** TEST SUCCEEDED **
```

- [ ] **5. Commit.**

```bash
git add Runner/App/AppModel.swift Runner/Core/Intents/TogglePauseIntent.swift Runner/Core/Intents/FinishRunIntent.swift RunnerTests/AppModelRunIntentTests.swift
git commit -m "feat: handle run controls through AppModel"
```

### Task 13: Present the saved summary and TrophyMath achievements on next open

**Files:**
- Modify: `Runner/App/RootTabView.swift`
- Modify: `Runner/Features/Record/WorkoutSummaryView.swift`
- Create: `RunnerTests/PendingCelebrationPresentationTests.swift`

**Interfaces**

- **Consumes:** `AppModel.pendingCelebration`, `clearPendingCelebration()`, `WorkoutSummaryView`, `TrophyMath.achievements(history:candidate:)`, and `ActivityWorkoutSummary`.
- **Produces:** `WorkoutSummaryView.init(workout:achievements:isSaving:isAlreadySaved:onSave:onDiscard:)` and a next-open summary sheet that clears only after Done.

- [ ] **1. Write the failing test.** Create `RunnerTests/PendingCelebrationPresentationTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

struct PendingCelebrationPresentationTests {
    @Test func candidateUsesTheRecordedWorkoutValues() {
        let workout = RecordedWorkout(
            type: .run,
            start: Date(timeIntervalSince1970: 1_750_000_000),
            end: Date(timeIntervalSince1970: 1_750_000_600),
            movingSeconds: 600,
            distanceMeters: 5_000,
            route: [],
            splitSeconds: [120, 120, 120, 120, 120]
        )
        let candidate = PendingCelebrationPresentation.candidate(from: workout)

        #expect(candidate.type == .run)
        #expect(candidate.date == workout.start)
        #expect(candidate.distanceMeters == 5_000)
        #expect(candidate.movingSeconds == 600)
        #expect(candidate.splitSeconds == workout.splitSeconds)
    }
}
```

- [ ] **2. Run it and verify RED.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected failure:

```text
error: cannot find 'PendingCelebrationPresentation' in scope
** TEST FAILED **
```

- [ ] **3. Write the minimal implementation.** Add this pure adapter at the bottom of `WorkoutSummaryView.swift`:

```swift
enum PendingCelebrationPresentation {
    static func candidate(from workout: RecordedWorkout) -> ActivityWorkoutSummary {
        ActivityWorkoutSummary(
            id: UUID(),
            type: workout.type,
            date: workout.start,
            distanceMeters: workout.distanceMeters,
            distanceEstimated: workout.distanceEstimated,
            movingSeconds: workout.movingSeconds,
            points: PointsEngine.workoutPoints(
                type: workout.type,
                distanceMeters: workout.distanceMeters
            ),
            calories: 0,
            splitSeconds: workout.splitSeconds,
            hasRoute: !workout.route.isEmpty
        )
    }
}
```

Add this property to `WorkoutSummaryView`:

```swift
    var isAlreadySaved = false
```

Replace its action-button stack with:

```swift
            VStack(spacing: 10) {
                Button(action: onSave) {
                    Group {
                        if isSaving {
                            ProgressView().tint(Color.rBackground)
                        } else {
                            Text(isAlreadySaved
                                 ? String(localized: "Done")
                                 : String(localized: "Save workout"))
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                        }
                    }
                    .foregroundStyle(Color.rBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Capsule().fill(Color.rLime))
                }
                .disabled(isSaving)
                if !isAlreadySaved {
                    Button(action: onDiscard) {
                        Text(String(localized: "Discard"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.rTextSecondary)
                    }
                    .disabled(isSaving)
                }
            }
            .padding(.bottom, 12)
```

In `RootTabView`, add `import SwiftData` and:

```swift
    @Query(sort: \WorkoutRec.start, order: .reverse)
    private var workouts: [WorkoutRec]
```

Add this sheet after the full-screen record cover:

```swift
        .sheet(item: $model.pendingCelebration) { workout in
            let candidate = PendingCelebrationPresentation.candidate(from: workout)
            let history = workouts
                .filter {
                    !($0.type == workout.type &&
                      $0.start == workout.start &&
                      $0.end == workout.end)
                }
                .map(ActivityWorkoutSummary.init(workout:))
            WorkoutSummaryView(
                workout: workout,
                achievements: TrophyMath.achievements(
                    history: history,
                    candidate: candidate
                ),
                isSaving: false,
                isAlreadySaved: true,
                onSave: { model.clearPendingCelebration() },
                onDiscard: { model.clearPendingCelebration() }
            )
        }
```

The exact start/type/end filter removes the locally saved candidate before calling `TrophyMath`; otherwise the candidate would appear in both `history` and `candidate`, suppressing or double-counting achievements.

- [ ] **4. Run the complete suite and verify GREEN.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected output:

```text
** TEST SUCCEEDED **
```

- [ ] **5. Commit.**

```bash
git add Runner/App/RootTabView.swift Runner/Features/Record/WorkoutSummaryView.swift RunnerTests/PendingCelebrationPresentationTests.swift
git commit -m "feat: show saved run celebration on next open"
```

### Task 14: Finish localization, version 1.10 metadata, and release verification

**Files:**
- Modify: `Runner/Resources/Localizable.xcstrings`
- Modify: `project.yml`
- Modify: `Runner/Info.plist`
- Modify: `RunnerWidgets/Info.plist`
- Create: `RunnerTests/HandsFreeReleaseContractTests.swift`

**Interfaces**

- **Consumes:** every user-facing string introduced in Phases 1–4 and both XcodeGen-managed product versions.
- **Produces:** Runner v1.10 metadata, complete en/fr hands-free strings, and regenerated app/extension projects.

- [ ] **1. Write the failing test.** Create `RunnerTests/HandsFreeReleaseContractTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

struct HandsFreeReleaseContractTests {
    @Test func runnerBundleVersionIsOnePointTen() {
        #expect(Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String == "1.10")
    }

    @Test func allHandsFreeStringsResolve() {
        let values = [
            String(localized: "Arm a run without unlocking Runner."),
            String(localized: "Start Run")
        ]
        #expect(values.allSatisfy { !$0.isEmpty })
    }
}
```

- [ ] **2. Run it and verify RED.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected failure:

```text
Expectation failed: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String → "1.9") == "1.10"
** TEST FAILED **
```

- [ ] **3. Write the minimal implementation.** Change `CFBundleShortVersionString` to `"1.10"` in the complete Runner and RunnerWidgets target blocks in `project.yml`. Change the matching value to `1.10` in both `Runner/Info.plist` and generated `RunnerWidgets/Info.plist`. Leave `CFBundleVersion` at `"11"`.

Edit `Localizable.xcstrings` textually only and insert these complete missing entries in alphabetical position:

```json
    "Arm a run without unlocking Runner.": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Armez une course sans déverrouiller Runner."
          }
        }
      }
    },
    "Start Run": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Commencer une course"
          }
        }
      }
    },
```

Do not add spoken kilometre splits, Siri phrases, auto-run detection, an Apple Watch target, or any RecordView redesign.

Regenerate:

```bash
xcodegen generate
```

- [ ] **4. Run final verification and verify GREEN.**

```bash
xcodebuild test -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -20
```

Expected final lines:

```text
** TEST SUCCEEDED **
** BUILD SUCCEEDED **
```

Then perform the final device flow with `./scripts/deploy.sh`: start from the Control, verify ready-to-running, auto-pause/resume audio, manual Pause/Resume, Finish, local save, ended Live Activity, and the next-open summary with `TrophyMath` achievements.

- [ ] **5. Commit.**

```bash
git add Runner/Resources/Localizable.xcstrings project.yml Runner/Info.plist RunnerWidgets/Info.plist RunnerTests/HandsFreeReleaseContractTests.swift
git commit -m "chore: release Runner 1.10 hands-free recording"
```
