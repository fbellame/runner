# Review log — what the labels in the comments mean

About ninety comments in `Runner/` are indexed against a review round:
`CRITICAL 3 fix: …`, `IMPORTANT 6 support: …`, `Task 8 connects manual runs
only`, `fix wave 3`, `Minor 6`. The prose beside each label explains itself, but
until this file existed the label itself resolved to nothing — you could follow
the reasoning in a paragraph and still not find out what the other four
CRITICALs were, or whether they had all been closed.

This is that index. It was reconstructed on **2026-09-05** from the comments
themselves, during the full-codebase audit, and it is a *log*: it records what
each label referred to at the time. It is not maintained against the code. When
it disagrees with the code, the code wins.

**Convention going forward:** don't add new numbered labels. A comment that says
*why* needs no index; a comment that needs an index is describing a review round
that belongs here instead.

---

## v1.10 hands-free epic — the numbered task list

`Task N` appears 38 times and refers to the phase plan in
[`plans/2026-07-24-hands-free-recording.md`](superpowers/plans/2026-07-24-hands-free-recording.md).
The ones cited in code:

| Label | What it built |
|---|---|
| Task 1 | Background location — the `UIBackgroundModes: location` entry the recorder needs to keep tracking with the screen off. |
| Task 7 | `RunAttributes` / `RunActivitySnapshot` — the ActivityKit-free value types the Live Activity is driven from. |
| Task 8 | `LiveActivityController` — the real presenter, orphan adoption, and `completeSave()`. |
| Task 9 | The `RunnerWidgets` extension target and its Live Activity view. |
| Task 12 | The Lock Screen intents (`StartRunIntent`, `TogglePauseIntent`, `FinishRunIntent`) and the intent-driven save. |
| Task 13 | The pending-celebration surface — showing the summary for a run finished from the Lock Screen, on next open. |

## CRITICAL — defects that could lose or duplicate a workout

**CRITICAL 1 — a cold intent could overwrite an unrecovered workout.**
`canAutoStart` reads `pendingResume`, and `pendingResume` is nil until something
reads the disk. A `LiveActivityIntent` can background-launch the app, so
`perform()` may run before `onLaunch()` ever does: a Start tap would arm a brand
new session whose checkpoint writes landed on top of a workout nobody had
recovered yet. Fixed by loading the checkpoint synchronously, before any
`await`, in `onLaunch()` / `onForeground()`, **and** by consulting the store
directly inside `startRunFromIntent()`. The auto-walk path carries the same
guard: `autoStart()` refuses while any checkpoint is on disk, because a failed
silent save deliberately leaves one behind after `isAutoSession` has cleared.
*Sites:* `AppModel.onLaunch/onForeground/startRunFromIntent`, `AutoWalkCoordinator.autoStart`.

**CRITICAL 2 — Lock Screen buttons that did the opposite of their label.**
Two halves. (a) A checkpoint written while manually paused always rehydrated as
`.recording`, so a Live Activity surviving process death showed "Resume" over a
session the recorder believed was running — `SessionCheckpoint.isPaused` fixes
that, decoding a missing key as `false` so 1.10-era files on the phone still
load. (b) ActivityKit activities outlive the process, so the Lock Screen could
show working-looking Pause and Finish buttons for a run the app had forgotten;
`resolveIntentSession()` rehydrates from the checkpoint instead of no-oping. Also
covers `completeSave()` announcing for walk and bike, which have no Live Activity
to end. *Sites:* `CheckpointStore`, `WorkoutRecorder.start/saveCheckpoint/completeSave`,
`AppModel.resolveIntentSession`, `SyncCoordinator.retryPendingSaves` (wave 3).

**CRITICAL 3 — a crash between the write and the checkpoint clear duplicated the run.**
Those two steps cannot be made atomic, so a kill in between leaves a checkpoint
for a run that is already saved, and "Save as-is" wrote it a second time under a
fresh `UUID()`. `SyncCoordinator.recordedWorkoutID(type:start:)` derives the id
from the session's own identity, turning that second write into an upsert. The
same round fixed the ordering in `finishRunFromIntent()` (celebration written
before the long save; checkpoint destroyed last, and only once the durable copy
is confirmed) and added `endStrandedLiveActivity()`, because the two
crash-recovery exits never call `begin()` and so never reach its orphan
reconciliation. *Sites:* `SyncCoordinator.recordedWorkoutID`, `AppModel.finishRunFromIntent/saveCheckpointedWorkout/discardPendingResume`, `WorkoutRecorder.endStrandedLiveActivity`, `LiveActivityController.endAllSurvivingActivities`.

**CRITICAL 4 — one in-flight flag dropped saves and called it success.**
`saveRecorded` guarded on a bare "a save is running" boolean and returned `nil`
for a dropped call — the same `nil` a clean save returned. A second, *different*
workout saved concurrently was silently discarded and reported as saved.
Replaced by `savesInFlight`, a set keyed on workout identity, and by
`RecordedSaveOutcome`, which names all four results. Distinct saves now overlap
rather than queue, which is also what made `retryPendingSaves` need its own
in-flight check. *Sites:* `RecordedSaveOutcome`, `SyncCoordinator.savesInFlight`,
`WorkoutRecorder.cancelAfterAuthorizationDenial`.

**CRITICAL 5 — a failed durable write announced as a saved run.**
`try?` swallowed the local write's error, so a run that was persisted nowhere
cleared its recovery checkpoint and spoke "Run saved". Every irreversible act is
now gated on `outcome.isLocallyDurable`, which is true only when a durable local
copy really exists — deliberately *not* "no HealthKit error", because a
HealthKit-only failure leaves the run safe locally and should still announce.
*Sites:* `SyncCoordinator.saveRecorded`, `AppModel.finishRunFromIntent/saveCheckpointedWorkout/enableAutoWalk`, `AutoWalkCoordinator.autoStop`, `DataStore.upsertFailureForTesting` (the test seam that proves it), `RecordView.save`.

> The one place CRITICAL 5 had *not* reached was the user-facing alert in
> `RecordView`, which described a failed save with the copy for a successful one.
> Fixed 2026-09-05 (audit F-02).

## IMPORTANT — defects that lose a cue, not a workout

**IMPORTANT 4 — a durably-saved run whose celebration file failed to write.**
The checkpoint is deliberately kept in that case, so `saveCheckpointedWorkout()`
re-persists the celebration and shows it — otherwise the run is safe but the
user is never told, and the in-memory celebration does not survive the process
death that made the recovery necessary.

**IMPORTANT 5 — a celebration file for a save that may never have landed.**
CRITICAL 3's ordering writes the celebration *before* the durable save, so a kill
in that gap leaves a file asserting `isAlreadySaved: true` for a row that might
not exist. `loadPendingCelebration()` treats a surviving checkpoint for the same
session as the tell and defers to the resume prompt.

**IMPORTANT 6 — an acknowledged celebration that came back.**
`clear()` was `try?`-silent, so a failed delete resurrected a dismissed
celebration on a later launch. Now it falls back to truncating the file (a
zero-byte file fails to decode, which reads as "nothing pending"), and if even
that fails the acknowledgement is recorded in `UserDefaults` — a different
storage mechanism, so it survives whatever is wrong with the file.
`CheckpointStore.clear()` got the same hardening, and `DataStore.workout(type:start:)`
exists so a checkpoint left by a pre-deterministic-id build reconciles onto its
existing row instead of duplicating.

**IMPORTANT 7 — auto-walk silence, by construction.**
The widget only renders the controls on manual-run Live Activities, but
repository code cannot prove the system never invokes an intent outside the
rendered button. Every intent entry point in `AppModel` therefore guards
`!recorder.autoStarted` itself, matching the guards already on every other
announcement site, rather than relying on that cross-target invariant.

## Minor

**Minor 6 — `presentsLiveActivity` folds in `state != .idle`.** Without it the
property read `true` before any session had started (`activity` defaults to
`.run`, `autoStarted` to `false`), e.g. during the launch permission prompt. It
also happens to make `discard()`'s two branches mutually exclusive, which that
method's doc comment notes without depending on.

## Fix waves

**Fix wave 3 (Task 8).** `begin()` must end every non-matching stray *before*
calling `Activity.request`, because ActivityKit caps concurrent activities and
would otherwise reject silently. That makes `begin()` able to return before
`activity` is set, which opens two races — a second `begin()` firing a second
request, and `end()`/`discard()` racing the deferred request into creating an
activity nobody will ever end. `LiveActivityRequestGate` closes both with a
generation counter. The same wave fixed `retryPendingSaves` comparing a legacy
row's random `rec.id` against a set keyed by deterministic ids.
