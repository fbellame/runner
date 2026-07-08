# Runner v1.2 — Phase 3b: Full-history Import

**Date:** 2026-07-08
**Branch:** `runner-v1`
**Epic:** v1.2 History & Trends (Phase 3b of 4)

## Goal

Import the user's **entire** HealthKit history (workouts + daily steps/points/streak
ledgers) rather than only the last 90 days, so History, records, Insights, and
per-run split analytics reflect all past activity.

## Problem

`SyncCoordinator` uses a fixed `static let windowDays = 90`. On **every**
foreground/launch, `performSync()`:
1. Reads HealthKit steps + workouts for the last 90 days (`dailySteps(daysBack:)`,
   `workouts(daysBack:)`).
2. Caches external `WorkoutRec`s for those workouts.
3. Rebuilds a `DayLedger` for each of the 90 days (steps → calories → distance →
   points → goal → streak) and upserts them.

Anything older than 90 days is never imported. Naively lifting the cap to "all
history" would make step (3) rescan **all-time** HealthKit and rebuild thousands of
ledgers on *every* foreground — unacceptable cost.

## Approach — one-time backfill, then rolling window

Chosen scope (user decision): import **everything** — workouts *and* daily ledgers
back to the earliest HealthKit sample. Realized safely as a **one-time backfill**:

- A persisted boolean `fullHistoryBackfilled` (via an injected `UserDefaults`,
  defaulting to `.standard`; a fresh suite is injected in tests).
- Each `performSync()` computes its window:
  - **Not yet backfilled** → window start = **earliest HealthKit sample date**
    (full import). On a *successful* pass, set `fullHistoryBackfilled = true`.
  - **Already backfilled** → rolling **90-day** window as today.
- Previously imported old ledgers and external workouts **persist** in the store;
  the rolling window only updates recent days, it never deletes older rows.

This gives full historical visibility with the full rescan paid **once**, not on
every foreground.

## Changes

### `HealthStoring` protocol + `HealthStore` + test mock

Add:

```swift
func earliestHistoryDate() async throws -> Date?
```

- Real `HealthStore`: query the earliest workout sample and earliest step sample
  (each `HKSampleQuery`, ascending start date, `limit: 1`); return the **minimum**
  of the two starts. `nil` when HealthKit has no relevant samples.
- Test mock (`RunnerTests`): return a configurable stub date.

### `SyncCoordinator`

- Inject persistence: add `defaults: UserDefaults = .standard` to `init` (keep the
  existing signature working via the default arg). Store a key
  `private static let fullHistoryKey = "fullHistoryBackfilled"`.
- Extract a **pure, testable** window helper:

  ```swift
  static func daysBack(backfilled: Bool, earliest: Date?, now: Date,
                       calendar: Calendar) -> Int
  ```

  - `backfilled == true` → `windowDays` (90).
  - `backfilled == false`, `earliest != nil` → number of days from
    `startOfDay(earliest)` to `startOfDay(now)` inclusive (`max(_, windowDays)` so a
    brand-new user still gets the normal 90-day floor).
  - `earliest == nil` → `windowDays`.
- `performSync()`:
  - Read `backfilled` from defaults; if `false`, call
    `health.earliestHistoryDate()` and compute `daysBack` via the helper;
    otherwise use `windowDays`.
  - Use `daysBack` everywhere `Self.windowDays` is currently used (both HealthKit
    queries, the `HealthMappers.window` call, the `0..<daysBack` day loop, and the
    `latestLedger(before:)` / `goalProvider(from:)` seeds).
  - On success, if it was a backfill pass, set `defaults.set(true, forKey:)`.
    (Leave the flag unset if the pass threw, so it retries next launch.)
- Streak: with `windowStart == earliest`, `latestLedger(before: windowStart)`
  returns nil → `initialStreak = 0`. Correct — nothing precedes the true start.
- Goals: `goalProvider(from: windowStart)` applies the current/most-recent goal to
  old days that predate any goal setting. Accepted caveat — old days show progress
  against today's goal.

### `ProfileView` — "Re-import full history"

Add a button/action that resets `fullHistoryBackfilled = false` and calls
`model.sync.syncNow()`, forcing a full rebuild (useful if the user grants broader
HealthKit access later or edits old data). Follows existing ProfileView action
patterns. New localized label with French.

## i18n

New keys in `Localizable.xcstrings` with French:

| English | French |
|---|---|
| Re-import full history | Réimporter tout l'historique |
| Imports all past activity from Apple Health | Importe toute l'activité passée depuis Apple Santé |

## Testing — `RunnerTests/SyncCoordinatorTests.swift` (extend)

- `daysBack` helper (pure): backfilled → 90; not-backfilled with an earliest date
  N days ago → N-day span; not-backfilled with `nil` earliest → 90; earliest more
  recent than 90 days → floored to 90.
- Integration with the existing mock health + fresh `UserDefaults(suiteName:)`:
  - First sync when flag unset → uses earliest date, imports old workouts, sets the
    flag.
  - Second sync → flag set → uses 90-day window (mock records the `daysBack` it was
    asked for).
  - A failing first pass leaves the flag unset.
- Mock `HealthStoring` gains `earliestHistoryDate()` returning a stub; verify no
  regression in existing sync tests.

## Success criteria

- Fresh install with old HealthKit data imports all past workouts + ledgers on
  first sync; the full rescan happens once (flag then gates it to 90-day rolling).
- Existing sync behaviour (recorded-save path, retry, day derivation) unchanged.
- Window helper unit-tested; sync integration tests green.
- French present for new strings.
- `xcodegen generate` clean; `xcodebuild … build test` green on an iPhone sim.

## Out of scope

- Deleting/pruning history.
- Backfilling data the user never had in HealthKit.
- Changing point/calorie formulas (only the *window* over which they're computed).
- Migrating the SwiftData schema (none required).
