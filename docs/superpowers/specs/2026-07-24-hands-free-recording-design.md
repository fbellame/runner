# Runner v1.10 — Hands-Free Recording

**Date:** 2026-07-24
**Status:** Approved design, ready for implementation planning

## Problem

Starting and stopping a run costs roughly a minute of fumbling at each end. The
phone lives in a zipped running pocket, so recording a workout means: unlock the
phone, tap the record button, pick an activity, tap GO, then get the phone back
into the pocket and start running. Finishing is the same in reverse, plus a slide
gesture.

Three distinct costs fall out of that, all confirmed as real pain:

1. **The data is wrong.** The fumbling minute at each end is recorded as part of
   the run. Duration is inflated, pace is diluted, and the route carries a
   stationary blob at both ends.
2. **The physical fumbling.** Digging the phone out, unlocking it, and navigating
   the app breaks the run — worse in cold or rain.
3. **Interruptions mid-run.** Pausing for a light, a break, or a detour is
   effectively impossible without stopping to dig the phone out.

Forgetting to stop a session is explicitly *not* one of the pains. This is about
friction, not memory.

### Available hardware

iPhone + AirPods. **No Apple Watch, no Action Button.** That rules out the
textbook answer (a watch app) and makes audio a first-class channel: with the
phone pocketed, the AirPods are the only feedback surface the user has.

### What already exists and is reusable

The codebase has more of this built than it appears:

- `AutoPauseDetector` already stops the clock 10s after speed drops below
  0.5 m/s for run/walk, and resumes 3s after it rises above. Traffic lights are
  most likely already handled correctly — the user simply has no way to *know*,
  because the phone is silent and pocketed. Part of pain (3) is a **feedback**
  problem, not a control problem.
- `WorkoutRecorder.start(activity:backdatedTo:)` already supports starting a
  workout at a moment in the past.
- `WorkoutRecorder.finish(endingAt:)` already supports trimming a trailing
  stationary segment. `AutoWalkCoordinator` uses it today.
- `AutoWalkCoordinator` establishes the pattern for a coordinator that sits
  beside the recorder and reaches the rest of the app through injected closures
  rather than a back-reference to `AppModel`.
- `SyncCoordinator.saveRecorded` is a single local-first save path already
  exercised by a silent, unattended caller.
- `CheckpointStore` establishes the persist-a-session-across-launches pattern.

## Decisions

Settled during brainstorming; recorded here so implementation does not relitigate
them.

| Question | Decision |
|---|---|
| Primary mechanism | Lock Screen Control + Live Activity ("one tap, never unlock") |
| Siri / voice control | Out of scope for v1.10. The App Intents built here make it an easy follow-up. |
| Auto-detect running | **Rejected.** GPS isn't running for the first minutes, so the start of the route would be lost — and for a run, the route is the point. |
| What the Control starts | Always a **run**. Walks already auto-record via `AutoWalkCoordinator`; rides arrive from Bixi through HealthKit. Running is the only activity that needs a fast manual start. |
| Deferred-start trigger | Reuse `AutoPauseDetector`, armed in the paused state. Its existing, tested resume rule un-freezes the clock. |
| Audio feedback | Spoken state changes only ("Run started", "Paused", "Resumed", "Run saved"). **No spoken km splits.** |
| Finish from lock screen | Saves immediately; the summary and trophy celebration surface on next app open. |

## Architecture

Four new pieces plus surgical changes to `WorkoutRecorder`. Every new type sits
*beside* the recorder and communicates through a narrow interface, following the
precedent `AutoWalkCoordinator` set — nothing reaches into `AppModel` and creates
a cycle.

| Piece | Location | Responsibility | Depends on |
|---|---|---|---|
| `RunnerWidgets` (new extension target) | `project.yml`, `RunnerWidgets/` | Hosts the Control and Live Activity UI. Presentation only, no logic. | `RunAttributes` |
| `StartRunIntent`, `TogglePauseIntent`, `FinishRunIntent` | `Runner/Core/Intents/` | `LiveActivityIntent`s. Each body is a one-liner delegating to an `AppModel` method. | `AppModel` |
| `LiveActivityController` | `Runner/Core/Recording/` | Owns the `Activity<RunAttributes>` lifecycle: begin, throttled update, end. | ActivityKit |
| `RunAnnouncer` | `Runner/Core/Recording/` | Speaks state changes over a ducked audio session. | AVFoundation |
| `PendingCelebrationStore` | `Runner/Core/Store/` | Persists a just-saved workout so the summary + trophies appear on next open. | — |

`LiveActivityController` and `RunAnnouncer` are each fronted by a protocol
(`LiveActivityPresenting`, `Announcing`) so tests never load ActivityKit or play
audio.

### Why `LiveActivityIntent`

Interactive Live Activity and Control buttons normally execute inside the widget
extension's process, which has no access to the running `WorkoutRecorder`.
`LiveActivityIntent` (iOS 17+) is the exception: it executes in the **app**
process, background-launching the app if needed. That is the single property the
whole design rests on.

## Honest timing

The mechanism that fixes pain (1). It is deliberately small, because
`AutoPauseDetector` already knows how to un-freeze a clock.

### Arming

- `AutoPauseDetector` gains `init(activity:startPaused:)`. When `startPaused` is
  true, `isPaused` begins true and the existing resume rule (3s above 0.5 m/s)
  governs the transition out.
- `WorkoutRecorder.start(activity:armed:)` builds the detector paused and sets
  `state = .autoPaused` before the first sample arrives.
- No change is required in `ingest`. Step 1 (`if state == .recording {
  advanceTimer }`) already refuses to accrue time while paused, and step 3's
  `if wasAutoPaused && !paused { timeAnchor = location.timestamp }` already
  un-freezes the clock at exactly the right instant.

### Rebasing `startedAt`

Arming alone is not sufficient. `startedAt` would still be the moment of the tap,
so `end - start` would still contain the dead minute — and `finish()` clamps
`movingSeconds` against that inflated elapsed value.

Therefore: on the **first** transition out of the armed state, the recorder
rebases `startedAt` to the un-freeze instant. Subsequent auto-pause cycles during
the run leave `startedAt` untouched; this happens once per session.

### Tail trim

The recorder tracks `lastMovingAt` — the timestamp of the most recent sample
processed while `state == .recording`. Every finish path (lock screen and in-app)
calls `finish(endingAt: lastMovingAt)`, so the stationary tail is dropped. The
machinery already exists; only the tracked value is new.

### Side effect worth keeping

Arming starts GPS warming while the phone is being pocketed, so a fix is
typically acquired by the time running begins. This is a real quality improvement
over today, where the first samples of a run are the least accurate.

## Flows

### Start

1. Press power to wake the Lock Screen.
2. Tap the **Start Run** control.
3. `StartRunIntent` runs in the app process: arms the recorder
   (`start(activity: .run, armed: true)`) and opens the Live Activity.
4. The Live Activity reads **"Ready — start moving"**.
5. The phone goes in the pocket; GPS warms.
6. Running begins. The detector resumes, `startedAt` rebases, the announcer says
   **"Run started"**, and the Live Activity flips to live stats.

### Mid-run

The Live Activity carries Pause/Resume, each with a spoken confirmation. Auto-pause
continues to work as it does today — but is now audible, which is the actual fix
for pain (3).

### Finish

1. Wake the Lock Screen; tap **Finish** on the Live Activity.
2. `FinishRunIntent` calls `finish(endingAt: lastMovingAt)`.
3. The workout is saved through `sync.saveRecorded` — the same local-first path
   `AutoWalkCoordinator` already uses.
4. The checkpoint is cleared, the workout is written to `PendingCelebrationStore`,
   the announcer says **"Run saved"**, and the Live Activity ends.
5. On next app open, `WorkoutSummaryView` presents the workout with any
   achievements from `TrophyMath`, then the pending record is cleared.

No unlock is required at any point in either flow.

### The in-app path is not a second-class citizen

Tapping **GO** inside `RecordView` suffers from exactly the same fumbling minute,
so it gets exactly the same treatment: GO arms the session rather than starting
the clock, and the HUD reads "Ready — start moving" until the first movement.
Slide-to-finish routes through `finish(endingAt: lastMovingAt)` like every other
finish path.

Likewise, the Live Activity is a property of *a session*, not of the Control:
any manually started run opens one too, so a run begun in the app can still be
paused and finished from the Lock Screen. Auto-started walks do **not** open one
— that feature is deliberately silent and must stay that way.

## Error handling

| Condition | Behaviour |
|---|---|
| Armed 10 minutes with no movement | Cancel the session, end the Live Activity, announce "Run cancelled". Without this, a mis-tap leaves GPS burning in a pocket. |
| Location permission denied when the intent fires | The Live Activity carries the message and the announcer speaks it. There is no alert to show from a locked screen. |
| Reduced (non-precise) location accuracy | Unchanged: request temporary full accuracy, and surface the existing banner in-app. The Live Activity carries a compact warning. |
| HealthKit save fails | Unchanged. `SyncCoordinator` is local-first and retries on its own. The announcement stays "Run saved" because locally it is. |
| User swipes the Live Activity away | The session keeps recording. The app remains reachable normally, and the in-app HUD is unaffected. |
| Intent fires while a session is already running | `StartRunIntent` is a no-op. The recorder is single-session and a manual session must never be hijacked — the same guarantee `AutoWalkCoordinator.canAutoStart` enforces. |
| Crash mid-session | Unchanged. `CheckpointStore` already covers this; the existing resume prompt still owns the recorder on next launch. |

## Testing

Everything load-bearing stays pure and testable in the style the repo already
uses. New unit tests:

- **`AutoPauseDetector`** — armed construction stays paused; resumes only after
  3s above threshold; a brief blip does not resume it.
- **`WorkoutRecorder`** — no moving time accrues while armed; `startedAt` rebases
  on first un-freeze and only once; `lastMovingAt` tracks the last recording
  sample; `finish(endingAt:)` drops the tail; an armed session that never moves
  produces no workout.
- **`RunAnnouncer`** — against a fake `Announcing`, assert the exact announcement
  sequence for a full session, and that no announcement fires twice.
- **`PendingCelebrationStore`** — round-trip, clear, and tolerance of a corrupt
  file.
- **`AppModel`** — the intent-facing methods (`startRunFromIntent`,
  `togglePauseFromIntent`, `finishRunFromIntent`) tested directly, without the
  App Intents runtime.

`LiveActivityController` is exercised through `LiveActivityPresenting` with a
spy; ActivityKit itself is never loaded in tests.

## Phasing

Each phase ships independently and is valuable on its own.

1. **Honest timing** — armed start, `startedAt` rebase, `lastMovingAt`, tail trim
   on every finish path. Pure logic, no new targets. Fixes "the data is wrong"
   before any new framework is involved.
2. **`RunAnnouncer`** — `Announcing` protocol, spoken state changes wired to
   recorder state transitions. Requires `audio` added to `UIBackgroundModes` and
   an `AVAudioSession` configured `.playback` with `.duckOthers`.
3. **Live Activity** — the `RunnerWidgets` extension target,
   `NSSupportsLiveActivities`, `RunAttributes`, `LiveActivityController`, and the
   Pause/Finish buttons.
4. **Start Run Control** — the Lock Screen / Control Center button, the three
   intents, `PendingCelebrationStore`, and summary-on-next-open.

## Risks

- **The one real unknown:** whether a `LiveActivityIntent` fired from a locked
  screen reliably background-launches the app *and* starts location updates from
  cold. This must be spiked on-device at the **top** of Phase 4, not discovered
  at the end of it. Fallback if it does not hold up: `openAppWhenRun = true` on
  the start intent, which costs a Face ID unlock but still removes the
  navigation and the activity picker.
- **ActivityKit update budget.** The Live Activity refreshes on state change and
  at most roughly every 5 seconds — never per GPS sample.
- **A new background mode.** Spoken feedback requires `audio` alongside the
  existing `location`. Standard for workout apps, but it is a new declaration and
  a new review consideration.
- **Localization.** Announcements and Live Activity strings are user-facing and
  must land in both `en` and `fr`. Note the standing constraint:
  `Localizable.xcstrings` has duplicate keys and must **never** be
  JSON-round-tripped — edit it textually.

## Explicitly out of scope

- Siri / voice commands (deliberate follow-up; the App Intents built here make it
  cheap).
- Auto-detection of runs (rejected — loses the start of the route).
- Any Apple Watch target.
- Spoken kilometre splits.
- Redesigning `RecordView` itself. Its panel, HUD, activity picker and
  slide-to-finish all stay exactly as they are.
