# Runner v1.4 — Trust real Health data (real calories, CO₂ avoided, distance audit)

**Date:** 2026-07-09 · **Branch:** `runner-v1.4-real-health-metrics` · **Target version:** 1.4 (build 6)

## Summary

For imported (external) workouts, prefer the metrics Health actually recorded
over the app's own estimates; estimate only to fill genuine gaps. Three grounded
outcomes, all confirmed against the user's real HealthKit data (≈718 Bixi rides
that carry real calories, a CO₂-avoided value, and — for at least some rides —
real distance; **no** heart rate, **no** elevation):

1. **Real calories** — read `activeEnergyBurned` per workout and use it instead of
   the MET-based estimate; fall back to the estimate only when Health has none.
2. **CO₂ avoided** — surface a per-ride and a lifetime "CO₂ saved" stat. Read
   Bixi's own metadata value when present; compute it from distance otherwise.
3. **Distance audit** — confirm rides that show distance in Health import with
   that real distance (estimate is a true last resort), widening the reader only
   if needed.

This continues the established "real-then-estimate" pattern already used for
`distanceEstimated`, and the pure-module + diagnostics architecture.

## Non-goals (YAGNI)

- No dedicated "Green Impact" screen, no CO₂ trends/charts.
- No heart rate, no elevation (absent from the user's data).
- No CO₂ for walk/run — CO₂ avoided is scoped to **bike** distance (Bixi framing).
- No re-writing of imported workouts back to HealthKit.

## Key domain facts (verified with the user)

- A representative Bixi ride in the Apple Health app shows: start/end time,
  duration, CO₂ not emitted, **calories**, **distance**.
- There is **no heart-rate data at all**, and no elevation on Bixi rides.
- HealthKit has **no standard CO₂ type** — "CO₂ not emitted" is Bixi's own custom
  workout metadata. Its exact key is not yet known and must be discovered on-device.

## Design

### 1. Data model (migration-safe inline defaults)

Mirror the existing `distanceEstimated` / `calories` migration pattern (inline
default → SwiftData lightweight-migrates an existing store).

`WorkoutRec` (SwiftData `@Model`):
- `var caloriesFromHealth: Bool = false` — true when `calories` came from Health's
  `activeEnergyBurned` rather than the MET estimate. (Existing `calories: Double`
  now holds the real value when available.)
- `var co2SavedGrams: Double = 0` — CO₂ avoided for this workout, in grams.
- `var co2FromHealth: Bool = false` — true when `co2SavedGrams` came from Bixi
  metadata rather than being computed.

`ExternalWorkout` (transport struct, not persisted):
- `let activeEnergyKcal: Double?` — nil when Health recorded none.
- `let co2SavedGrams: Double?` — nil when no CO₂ metadata was found.
- Both added to the initializer with `nil` defaults so existing call sites compile.

### 2. Reading real data (`HealthStore`)

- Add `HKQuantityType(.activeEnergyBurned)` to `readTypes`.
- In `workouts(daysBack:)`, per workout:
  - **Energy:** `activeEnergyKcal` = `workout.statistics(for: activeEnergyBurned)?
    .sumQuantity()?.doubleValue(for: .kilocalorie())`, falling back to
    `workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())`. `nil`/`0` → nil.
  - **CO₂:** read `workout.metadata` at the discovered Bixi key; parse the numeric
    value into grams (handle a kg-vs-g unit; see §4). Missing/unparseable → nil.

### 3. Prefer-real logic (`SyncCoordinator`, `CalorieEngine`)

- External-workout upsert:
  - `calories = w.activeEnergyKcal ?? metEstimate(w)`;
    `caloriesFromHealth = (w.activeEnergyKcal != nil)`.
  - `co2SavedGrams = w.co2SavedGrams ?? CO2Estimator.avoidedGrams(type: w.type, distanceMeters: w.distanceMeters)`;
    `co2FromHealth = (w.co2SavedGrams != nil)`.
- Our own recorded (GPS) workouts have no Health energy and no CO₂ metadata → keep
  the MET estimate (`caloriesFromHealth = false`) and computed CO₂.
- **Day totals:** `WorkoutEnergyInput` gains `let realKcal: Double?`.
  `CalorieEngine.dayCalories` uses `realKcal` when present, else the MET
  computation. The everyday-step de-duplication (subtracting run/walk workout
  foot-steps) is unchanged and independent of the calorie source.

### 4. New pure module `CO2Estimator`

Foundation-only, same shape as `WorkoutEstimation` / `SplitStats`:

```
enum CO2Estimator {
    /// Avg passenger-car tailpipe CO₂, grams per km. Named for easy tuning.
    static let carGramsPerKm = 192.0
    /// Grams of car CO₂ avoided by covering this distance by bike. 0 for non-bike.
    static func avoidedGrams(type: ActivityType, distanceMeters: Double) -> Double
}
```

- Returns 0 for non-bike types and for non-positive distance.
- `192 g/km` is a documented average-car figure; defined as a single constant so a
  future tweak (or making it configurable) is a one-line change.

Bixi-metadata parsing lives next to the reader (in `HealthStore` / a small helper):
given the metadata value (number or numeric string) and an assumed unit, return
grams. If the value looks like kilograms (small magnitude, e.g. < 100) treat as kg
→ ×1000; the discovery dump (§6) confirms the real unit before we finalize the
threshold.

### 5. Surfacing

- **WorkoutDetailView** — add two tiles to the existing Points / Distance / Time row
  (wrap to a second row as needed):
  - **Calories** — shown when `calories > 0`; marked as an estimate (reuse the `~`
    convention or an "est." caption) when `!caloriesFromHealth`.
  - **CO₂ saved** — shown only when `co2SavedGrams > 0` (i.e. bike rides), formatted
    in kg (e.g. `0.84 kg`).
- **Lifetime total** — `ActivityStats` sums lifetime CO₂ saved across all workouts;
  surfaced as a compact "🌱 X kg CO₂ saved" line in the History/Records area.

### 6. Distance audit + metadata discovery (`diagnosticsReport`)

Extend the existing 10-year workout scan to, for a handful of cycling workouts,
dump: all `metadata` keys and values, the readable distance and **which** source
produced it (per-type `distanceCycling` / `distanceWalkingRunning` / aggregate
`totalDistance` / none), and the `activeEnergyBurned` value. This:
- reveals Bixi's exact CO₂ metadata key + unit (feeds §2/§4),
- confirms rides with Health-visible distance import non-zero (no logic change
  expected — estimation only fires when distance reads 0),
- flags whether any distance is hidden in metadata (would justify widening
  `workoutDistanceMeters`).

## Testing

Pure-module and logic tests (no HealthKit needed):
- `CO2Estimator`: bike distance → expected grams; non-bike → 0; zero/negative
  distance → 0; a known distance matches `km × 192`.
- Calorie preference: `ExternalWorkout` with `activeEnergyKcal` → `WorkoutRec.calories`
  equals it and `caloriesFromHealth == true`; without → MET estimate and
  `caloriesFromHealth == false`.
- CO₂ preference: `ExternalWorkout` with `co2SavedGrams` → persisted value and
  `co2FromHealth == true`; without → computed and `co2FromHealth == false`.
- `CalorieEngine.dayCalories`: a `WorkoutEnergyInput` with `realKcal` uses it
  instead of the MET number; step de-dup unchanged.
- CO₂ metadata parsing: numeric and string values, g vs kg, → grams; garbage → nil.

Update the `FakeHealthStore` to carry the new `ExternalWorkout` fields.

## Housekeeping

- French strings for new labels ("Calories", "CO₂ saved" / "CO₂ économisé",
  lifetime "X kg de CO₂ évité", any "est." caption).
- Bump `MARKETING_VERSION` 1.4 / `CURRENT_PROJECT_VERSION` 6 in `project.yml`.
- `xcodegen generate` → `xcodebuild … build test` on the iPhone 17 simulator, all
  green, before committing. Deploy to device to read the diagnostics dump and
  confirm the CO₂ key/unit and real-vs-estimated calorie labelling in the wild.

## Open item resolved during implementation

The exact Bixi CO₂ metadata **key and unit** are discovered from the on-device
diagnostics dump (§6). Until then the reader matches a `co2`/`carbon`
case-insensitive key heuristic and the compute-fallback guarantees a sane value,
so the feature is correct even if the key is never matched.
