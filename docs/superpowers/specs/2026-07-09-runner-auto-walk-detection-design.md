# Auto-start walk sessions (v1.5)

Date: 2026-07-09

## Problem

Walking is the most common activity, yet it is the one the app most often misses.
A walk is only ever recorded when the user remembers to open Runner, tap Record,
pick Walk, and tap Start. By the time that ritual completes the walk is usually
underway or over.

The app should notice that the user has been walking for more than five minutes
and record the walk on its own.

## Decisions

Four decisions, taken during brainstorming, fix the shape of the feature:

1. **Detection scope: foreground plus recent history.** CoreMotion provides live
   activity updates while the app runs, and a queryable seven-day activity
   history. On returning to the foreground the app replays the recent history to
   catch a walk that began while it was closed and is still going. No Always
   location authorization, no continuous background wake-ups, no battery cost.

2. **Firing behaviour: silent auto-start.** No banner, no prompt, no sheet. The
   session simply begins.

3. **Stopping: silent auto-stop and auto-save.** Five continuous minutes of not
   walking ends the session and writes it to Health. Silence at the start forces
   silence at the end — nothing else would ever finish the session, and a session
   left running holds GPS open and inflates its own duration.

4. **The pre-detection minutes are backdated.** The workout starts when CoreMotion
   says walking began, not when detection fired. The distance for that opening
   stretch, which no GPS observed, is read from HealthKit and flagged estimated.

## Architecture

Four new units, each with one purpose, each testable without a device. The
protocol-over-system-framework pattern follows `LocationProviding` /
`SystemLocationProvider`, already established in this codebase.

### `MotionActivityProviding` (`Runner/Core/Recording/`)

A protocol over `CMMotionActivityManager`, and the only file in the project that
imports CoreMotion.

```swift
struct MotionSample: Equatable, Sendable {
    let isWalking: Bool
    let isUnknown: Bool     // no usable classification
    let isLowConfidence: Bool
    let at: Date
}

@MainActor
protocol MotionActivityProviding: AnyObject {
    static var isAvailable: Bool { get }
    var isAuthorized: Bool { get }
    func requestAuthorization() async
    func startUpdates(_ onSample: @escaping (MotionSample) -> Void)
    func stopUpdates()
    func history(from: Date, to: Date) async -> [MotionSample]
}
```

`SystemMotionActivityProvider` implements it against `CMMotionActivityManager`;
`FakeMotionActivityProvider` implements it for tests.

A `CMMotionActivity` maps to a `MotionSample` as follows: `isWalking` is the
activity's `walking` flag; `isUnknown` is true when `unknown` is set or when no
activity flag at all is set; `isLowConfidence` is true when `confidence == .low`.

### `WalkDetector` (`Runner/Core/Recording/`)

A pure value-type state machine, mirroring `AutoPauseDetector`. It consumes
timestamped `MotionSample`s and emits an outcome. It knows nothing about
recording, HealthKit, or the app.

```swift
struct WalkDetector {
    enum Outcome: Equatable {
        case start(walkBeganAt: Date)
        case stop(lastWalkingAt: Date)
    }
    static let startAfter: TimeInterval = 300   // 5 min continuous walking
    static let stopAfter: TimeInterval = 300    // 5 min continuous not-walking
    static let grace: TimeInterval = 60         // blips shorter than this don't break a run

    private(set) var isWalkSession = false

    mutating func update(_ sample: MotionSample) -> Outcome?
}
```

Because the detector is driven by sample timestamps rather than a wall clock,
replaying history through it is identical to feeding it live. One code path
serves both the foreground stream and the app-was-closed catch-up.

**Rules.**

- A low-confidence sample is discarded. It is never fed to the machine as
  evidence of not-walking.
- An unknown sample carries no information: it neither extends nor breaks the
  current run.
- Not-walking shorter than `grace` does not break a walking run. Traffic lights,
  waiting to cross, and standing still are normal inside a walk; without this the
  five-minute clock would reset every block and auto-start would never fire.
- Symmetrically, walking shorter than `grace` does not break a not-walking run,
  so crossing a room while otherwise seated cannot resurrect a session that is
  about to stop.
- `start` is emitted once, when walking has run for `startAfter`, carrying the
  timestamp at which that run began. `stop` is emitted once, when not-walking has
  run for `stopAfter`, carrying the last timestamp at which the user was walking.
- No `stop` without a preceding `start`. No second `start` while a session runs.

### `AutoWalkCoordinator` (`Runner/Core/Recording/`)

`@MainActor @Observable`, owned by `AppModel`. It wires motion samples into the
detector and acts on the detector's output. It holds the guards.

- On `.start(walkBeganAt:)` → `recorder.start(activity: .walk, backdatedTo: walkBeganAt)`.
- On `.stop(lastWalkingAt:)` → `recorder.finish(endingAt: lastWalkingAt)`, backfill
  distance, then `sync.saveRecorded(...)`.

**Guards.** Auto-start is suppressed unless all of the following hold:

- `recorder.state == .idle` — a manually started run is never interrupted.
- `pendingResume == nil` — the crash-resume prompt owns the recorder until answered.
- `showRecordSheet == false` — the user is not already in the record UI.
- the motion provider is available and authorized.

When motion authorization is absent or denied the coordinator is a silent no-op
and the app behaves exactly as it does today. This is not an error state.

**Foreground catch-up.** `AppModel.onForeground` asks the coordinator to query
`history(from: now - 30min, to: now)`, replay it through the detector, and then
attach the live stream.

**The degenerate save.** A detected walk whose total distance — GPS plus HealthKit
backfill — is under 100 m is discarded rather than saved. Silent
auto-save means no human is present to reject a misdetection, so the filter must
live in the code. 100 m is the threshold `RecordedWorkout.pace` already uses to
decide there is too little signal to be meaningful.

### `WorkoutRecorder` — two additive entry points

```swift
func start(activity: ActivityType, resumeFrom: SessionCheckpoint? = nil, backdatedTo: Date? = nil)
func finish(endingAt: Date? = nil) -> RecordedWorkout
```

`backdatedTo` sets `startedAt` to the true walk start and seeds `movingSeconds`
with the elapsed pre-GPS interval, so duration is honest from the first sample.
`endingAt` supplies the true end date, so the stationary tail that triggered the
stop is not baked into the workout. Both parameters default to the current
behaviour; every existing call site is unchanged.

## Data flow: the backdated distance

The pre-detection stretch has a duration but no route. Rather than guess at start
time, the coordinator waits until finish and then asks HealthKit for
`distanceWalkingRunning` over the window between the true walk start and the
first GPS point, adding the result to the GPS distance.

This needs one new `HealthStoring` method, since the existing
`dailyWalkRunDistance(daysBack:)` only buckets by whole day:

```swift
func walkRunDistance(from: Date, to: Date) async throws -> Double
```

The result sets `distanceEstimated`, the flag `WorkoutRec` already carries for
the Bixi estimated-distance path. One wrinkle: `SyncCoordinator.saveRecorded`
currently drops that flag, letting `upsertWorkout` default it to `false`. It must
be threaded through. `RecordedWorkout` gains `distanceEstimated: Bool = false`
and `autoStarted: Bool = false`.

The route line simply begins where GPS did. The existing `afterGap` mechanism
already draws this honestly, with no line to a place the user was not observed.

## Interaction with auto-pause

`AutoPauseDetector` and `WalkDetector` operate at different timescales and mean
different things, and do not conflict.

- Auto-pause stops the clock after 10 stationary seconds, so a red light does not
  inflate moving time.
- Auto-stop ends the session after 5 not-walking minutes.

A session may sit auto-paused for four minutes and resume without ever being at
risk. Because moving-time already excludes the paused tail, `finish(endingAt:)`
is correcting the *end date*, not the duration.

## The location-permission constraint

The app holds When In Use. An auto-start that fires while the app is in the
foreground gets GPS. An auto-start fired from live motion updates while the app
is backgrounded will not, because When In Use plus `allowsBackgroundLocationUpdates`
still requires the session to have begun in the foreground.

In practice:

- A walk detected while the app is open records a full route.
- A walk detected on foreground-return backdates correctly and records the route
  from that moment onward.
- A walk taken entirely with the phone pocketed and the app closed becomes a
  backdated, Health-distance-only workout with a short or empty route. Honest,
  and better than losing it.

Chasing Always authorization is explicitly out of scope, per decision 1.

## Persistence and permissions

- `WorkoutRec` gains `autoStarted: Bool = false` and keeps `distanceEstimated`.
  The inline default lets SwiftData lightweight-migrate the existing store, the
  pattern commit `6c291de` established for `calories` and `co2SavedGrams`.
- `autoStarted` surfaces in no UI. It exists so that "why is this walk here" has
  an answer later, and so History can filter on it if wanted.
- `Info.plist` gains `NSMotionUsageDescription`.
- `AppModel.onLaunch` requests motion authorization alongside the existing
  HealthKit request.

## Testing

`WalkDetectorTests` carries the weight, since the detector holds the logic:

- start fires at exactly `startAfter` of continuous walking, not before;
- stop fires at exactly `stopAfter` of continuous not-walking, not before;
- a not-walking blip shorter than `grace` does not reset the walking run;
- a not-walking blip longer than `grace` does reset it;
- a walking blip shorter than `grace` does not cancel a pending stop;
- unknown samples neither extend nor break a run;
- low-confidence samples are ignored entirely;
- no stop without a start; no double start.

`AutoWalkCoordinatorTests`, using `FakeMotionActivityProvider`, the existing
`FakeHealthStore`, and a fake location provider:

- no auto-start while the recorder is recording;
- no auto-start while a resume is pending;
- silent no-op when motion is unauthorized;
- the started session is backdated to the walk start;
- the finished workout ends at the last walking timestamp, not at stop time;
- HealthKit backfill is added and `distanceEstimated` is set;
- a walk whose total distance is under 100 m is discarded, not saved;
- foreground catch-up replays history and can start a session.

`FakeHealthStore` gains the ranged-distance method. The existing 162 tests must
stay green; no existing code path changes except the `distanceEstimated`
threading in `saveRecorded`.

## Known uncertainties

- **The 60-second grace is a guess.** The shape is right; the number wants tuning
  against real walks. It is a named constant so that is a one-line change.
- **CoreMotion's history is sparser than its live stream on some devices.** The
  30-minute lookback may need to grow if walks are being missed.
