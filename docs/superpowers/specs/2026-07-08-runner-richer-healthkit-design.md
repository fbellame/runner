# Runner v1.3 — Richer HealthKit Integration

**Date:** 2026-07-08
**Branch:** `runner-v1`

## Motivation (from device diagnostics)

Real HealthKit contents for the user:
- **718 workouts, all `cycling`, source Bixi, 0 with distance.** Bixi (bike-share)
  writes cycling workouts with **no distance sample** — the distance does not exist
  in HealthKit, so every Bixi ride imports as 0 km → 0 points → useless.
- **Walking/running exists only as `distanceWalkingRunning` samples**, not as
  `HKWorkout` objects, so Runner (which imports workouts) never surfaces it.
- Data goes back to **2024-03-31** (workouts) / **2018** (steps), but History only
  displays the last **13 weeks**.

Three confirmed changes, each independent.

## A. Estimated distance for distance-less rides

When an imported workout has **no readable distance** (real meters == 0) but has a
positive duration, estimate distance from duration × an average speed, and mark it
estimated so the UI can show it's approximate.

- New pure constant module `Runner/Core/Health/WorkoutEstimation.swift`:
  ```swift
  enum WorkoutEstimation {
      // ~15 km/h average city cycling.
      static let cyclingMetersPerSecond = 15_000.0 / 3600.0
      static func estimatedMeters(type: ActivityType, movingSeconds: Double) -> Double? {
          guard movingSeconds > 0 else { return nil }
          switch type {
          case .bike: return movingSeconds * cyclingMetersPerSecond
          case .run, .walk: return nil   // ambient run/walk handled in B; workouts here keep real distance
          }
      }
  }
  ```
- `ExternalWorkout` gains `let distanceEstimated: Bool`.
- `HealthStore.workouts(...)`: after computing real `meters` via `workoutDistanceMeters`,
  if `meters == 0`, try `WorkoutEstimation.estimatedMeters(type:movingSeconds:workout.duration)`;
  if non-nil, use it and set `distanceEstimated = true`. Otherwise `distanceEstimated = false`.
- **Model change (migration-safe):** `WorkoutRec` gains `var distanceEstimated: Bool = false`
  (inline default → SwiftData lightweight migration, same pattern as `calories`).
- `DataStore.upsertWorkout(...)` gains a `distanceEstimated: Bool = false` parameter,
  assigning it on both insert and update.
- `SyncCoordinator.performSync` external-workout upsert passes `w.distanceEstimated`.
- **Points:** no code change — `PointsEngine.workoutPoints` now sees non-zero km, so
  Bixi rides earn points automatically.
- **UI marker:** where a workout distance is shown and `distanceEstimated == true`,
  prefix with `~` (e.g. `~3.8 km`). Touch points: `WorkoutRowCard`, `WorkoutDetailView`
  stat tile, and History records rows. Add a small helper
  `Format.km(_:estimated:)` or format inline. Keep it subtle.

## B. Ambient walking/running distance in daily totals

Walk/run distance lives as `distanceWalkingRunning` samples, not workouts. Fold it
into the **daily distance total** only — NOT into points (steps already reward
ambient movement; adding distance points would double-count) and NOT as synthetic
workouts (they are not sessions; keep records/insights workout-based).

- `HealthStoring` + `HealthStore`: new
  `func dailyWalkRunDistance(daysBack: Int) async throws -> [Date: Double]`, summing
  `distanceWalkingRunning` per day via `HKStatisticsCollectionQuery` (mirror
  `dailySteps`). Fake store returns `[:]`.
- `SyncCoordinator.performSync`: fetch it alongside steps/workouts and **add** each
  day's ambient walk/run meters to that day's `DayDerived.distanceMeters` (on top of
  workout distance). Guard against double counting: this user has no run/walk
  workouts, but if any exist their workout distance already counts — accept minor
  overlap, documented, since ambient distance and a recorded run over the same period
  are both real movement. (Simplicity over perfect dedup.)
- Effect: Today's "distance", History day detail, and the ledger-based distance stat
  reflect real daily distance. Workout-based lifetime totals / records / insights are
  unchanged (still sessions only).

## C. Extend history beyond 13 weeks

- `HistoryView` heatmap: raise `weekCount` from 13 to **52** (one year; the heatmap is
  already horizontally scrollable). Label updates to "Last 52 weeks".
- `HistoryView` chart range picker: add a **"Year"** option (365 days) alongside
  Week (7) / Month (30). `HistoryMath.dailySeries` already takes `lastN`, so only the
  Picker tag + label change.
- No change needed to import: the one-time full backfill already builds ledgers back
  to the earliest sample; older ledgers persist across the rolling 90-day syncs.

## i18n

New/updated English keys with French: "Last 52 weeks" → "52 dernières semaines",
"Year" → "Année", and an estimated-distance hint if surfaced (e.g. a footnote
"~ = estimated" → "~ = estimé"). Assemble from localized fragments.

## Testing

- `WorkoutEstimationTests` (Swift Testing): bike estimate = duration × speed;
  run/walk → nil; zero/negative duration → nil.
- `HealthMappers`/mapping is exercised via existing patterns; add a `SyncCoordinator`
  test asserting a 0-distance bike external workout is stored with estimated distance
  and non-zero points, and that `dailyWalkRunDistance` adds into `DayDerived.distanceMeters`.
  Extend `FakeHealthStore` with `walkRunByDay` + `dailyWalkRunDistanceDaysBack`.
- Existing suites must stay green.

## Success criteria

- Bixi rides show estimated km (with `~`), earn points, and appear in totals/records/insights.
- Daily distance totals include ambient walking/running.
- History heatmap spans up to a year; chart offers a Year range.
- Migration from the existing store is seamless (no data loss; `distanceEstimated`
  backfills false).
- `xcodebuild build test` green on an iPhone sim; deployed build bumps CFBundleVersion.

## Out of scope

- Turning ambient walk/run into sessions or awarding it points.
- Altitude / flights-climbed / active-energy ingestion (possible later "richer
  metrics" phase).
- Re-deriving distance for real GPS workouts (already correct).
