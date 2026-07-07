# Runner v1.1 — Body & Calories Design

**Date:** 2026-07-07
**Status:** Approved pending user review
**Owner:** Farid (faridautomatic@gmail.com)
**Builds on:** [2026-07-05 Runner app design](2026-07-05-runner-fitness-app-design.md)

## 1. What & Why

Runner v1 turns daily movement into one motivating **points** number. v1.1 makes it
more powerful without changing that core: it adds **body metrics** (height, weight,
age, sex) and an **estimated calories-burned** metric, surfaces more on the Today
screen, and adds a **per-day detail** view reachable from History.

**Decisions from brainstorming (2026-07-07):**

- Calories = **burn only**. No food logging, no net-calorie balance, no calorie goal.
- Body metrics come from **Apple Health, with manual override**.
- Today screen gains: **calories burned**, **distance + active time**, and a
  **7-day trend mini-chart**. (No calorie goal ring.)
- **Points engine is untouched.** Calories are a separate, parallel metric.
- Calories are **de-duplicated** against workout steps (unlike points, which
  intentionally double-count) — an inflated calorie number is misleading in a way
  bonus points are not.
- Trend sparkline **defaults to points**, toggleable to calories.

No new third-party dependencies. Dark "Electric Night" identity unchanged.

## 2. Scope

### In scope

1. **Profile** module + screen: read height/weight/DOB→age/sex from HealthKit;
   manual override stored locally; graceful empty states.
2. **CalorieEngine**: pure, testable MET-based estimator (no heart-rate sensor).
3. **Today** additions: calories breakdown, stat strip (kcal / km / active min),
   7-day trend sparkline.
4. **Day Detail** screen from History (heatmap + charts entry points).
5. Data-model additions (`UserProfile`; derived calorie/distance/time fields),
   all cache-safe and rebuildable.
6. French strings + locale-aware formatting for the new UI.

### Out of scope (unchanged intent)

- Food / nutrition logging, net-calorie balance, macros.
- Calorie goals or rings.
- Heart-rate / any new sensor.
- Changes to the points engine, streak, or multiplier rules.

## 3. Body Metrics & Profile

New module **`Core/Profile`** and a **Profile screen** (opened from Settings; a
one-time prompt appears on first launch of v1.1 inviting the user to review it).

### Sources & precedence

| Field | HealthKit source | Notes |
|---|---|---|
| Height | `HKQuantityType(.height)`, latest sample | Used for stride estimation |
| Weight | `HKQuantityType(.bodyMass)`, **latest** sample | Re-read on each app open unless manually overridden |
| Age | `HKCharacteristicType(.dateOfBirth)` → years | |
| Sex | `HKCharacteristicType(.biologicalSex)` | Used for stride/BMR coefficients |

- Manual values live in a single-row `UserProfile` (SwiftData). A per-field
  `isManual` flag makes a manual value **take precedence** over Health until the
  user clears it (clearing reverts that field to the Health value).
- **Permissions:** extend the existing HealthKit read authorization request to
  include height, body mass, date of birth, biological sex. Denial or absence is
  handled by empty states — never fabricated numbers.

### Empty-state behavior

- **No weight known** (the load-bearing input): calorie UI shows an
  *"Add your weight to see calories"* card instead of numbers, mirroring the v1
  steps explainer. Points and everything else keep working.
- Missing height → fall back to a sex-based average stride; missing sex → use a
  neutral coefficient. These fallbacks are only for stride/step estimation, never
  shown as if measured.

## 4. Calorie Engine

**`Core/CalorieEngine`** — pure Swift, no iOS imports, unit-tested like
`PointsEngine`. Model is **MET × weight × time**, fully explained in-app
(transparency is a feature, as with points).

### Inputs

- `ProfileSnapshot`: `weightKg`, `heightCm?`, `sex`, `age?`.
- Per workout: `type`, `distanceMeters`, `movingSeconds`.
- Daily: all-day `steps`.

### Workout calories

```
avgSpeed = distanceMeters / movingSeconds          // m/s, moving time only
MET      = met(type, avgSpeed)                      // per-activity lookup table
kcal     = MET * weightKg * (movingSeconds / 3600)
```

Per-activity speed→MET lookup tables (piecewise, from the Compendium of Physical
Activities), one each for **run**, **walk**, **bike**. Cycling is handled here even
though it produces no steps.

### Everyday-movement calories (de-duplicated)

Recorded run/walk workouts also raise the all-day step count, so counting both
would double-count. To de-duplicate:

```
stride            = strideMeters(heightCm, sex)                 // ~0.415·h (m), 0.413 (f); fallback avg
workoutWalkKm     = Σ distanceKm of today's run+walk workouts   // bike excluded (no steps)
workoutSteps      = round(workoutWalkKm * 1000 / stride)
everydaySteps     = max(0, steps - workoutSteps)
everydayKcal      = everydaySteps * kcalPerStep(weightKg, stride)
```

`kcalPerStep` converts a step to walking distance (`stride`) and applies the walking
MET at a default everyday pace — a small per-step figure scaled by weight and stride.

### Day total

```
activeCalories = everydayKcal + Σ workoutKcal
```

All calorie outputs are **`Double?`** — `nil` when weight is unknown (drives the
empty state). Values are labeled **estimates** everywhere they appear; an
"About calories" section in Settings states the exact formula.

## 5. Today Screen Additions

Order preserved: header → points block (unchanged, first) → points breakdown
(unchanged) → **new calorie + stats content** → mini-map → explainers.

- **Calories card**: `🔥 <kcal> kcal` total with a breakdown that visually parallels
  the points breakdown — a "steps" row and one row per workout. Hidden/replaced by
  the empty-state card when weight is unknown.
- **Stat strip**: three compact tiles — `🔥 kcal · 📏 total km today · ⏱️ active min`.
  Distance/active-time come from today's workouts (`DayLedger` derived fields).
- **7-day trend sparkline** (Swift Charts): last 7 days, **defaults to points**, a
  small segmented toggle switches to calories. Goal rule-line shown in points mode.

## 6. Day Detail Screen

New **`Features/History/DayDetailView`**, pushed when the user taps a day in the
**heatmap** or a bar in the History charts.

- Header: the date, gold/streak status, goal that applied that day (`goalAtThatTime`).
- Sections: **points** breakdown (steps / workouts / multiplier), **calories**
  breakdown, **totals** (distance, active time).
- **Workout list** for that date; each row taps through to the existing
  `WorkoutDetailView` (route, splits, stats).
- Pure aggregation over `DayLedger` + that day's `WorkoutRec`s via `HistoryMath`
  and `CalorieEngine`; **no new storage**.

## 7. Data Model Changes

Minimal and **cache-safe** — SwiftData remains a rebuildable cache over HealthKit.

```
UserProfile   (single row)
  heightCm: Double?      isHeightManual: Bool
  weightKg: Double?      isWeightManual: Bool
  birthDate: Date?       isBirthManual: Bool
  sexRaw: String?        isSexManual: Bool

WorkoutRec  (+ field)
  calories: Double       // persisted at save time from the profile snapshot,
                         // so historical workouts keep the weight they burned at

DayLedger  (+ derived fields, recomputed by the existing ledger rebuild path)
  activeCalories: Double
  distanceMeters: Double
  activeSeconds: Double
```

- `WorkoutRec.calories` is computed once at save and persisted (a workout's calories
  should reflect the body at the time it happened). Backfilled/imported workouts get
  calories computed once from the current profile, then persisted.
- `DayLedger`'s new fields are **derived**; the same recompute that already runs on
  new steps / new-or-deleted workout / goal edit also fills them. A full cache
  rebuild reconstructs them from HealthKit + `WorkoutRec`.
- **Migration:** additive only. New non-optional fields get sensible defaults
  (`0`); a one-time pass recomputes calories/derived fields on first v1.1 launch.

## 8. Internationalization

- New String Catalog entries: *calories, calories brûlées, profil, taille, poids,
  âge, sexe, minutes actives, tendance, estimation*.
- Height/weight/number formatting via system locale (`Measurement` formatters where
  appropriate). Metric only, consistent with v1.

## 9. Testing

- **CalorieEngine** (pure): MET lookups at boundary speeds per activity; workout
  kcal correctness; step de-duplication (a run's steps are subtracted, a bike's are
  not); `nil` weight → `nil` output; stride fallbacks; everyday-only vs mixed days.
- **Profile resolution**: Health value used when present; manual override wins;
  clearing a manual field reverts to Health; missing fields.
- **Day Detail aggregation**: totals match the sum of the day's workouts + ledger.
- **Migration/backfill**: derived fields and workout calories populate correctly on
  first v1.1 launch and after a full cache rebuild.
- **Device check**: calories are plausible vs Apple Health for a real run/walk/ride;
  Profile reads real Health values; French UI renders.

## 10. Project Layout (additions)

```
Runner/
  Core/Profile/        (UserProfile resolution: Health + manual override)
  Core/CalorieEngine/  (pure MET model, stride, de-dup)
  Features/Profile/    (ProfileView)
  Features/History/    (+ DayDetailView)
  Features/Today/      (+ calorie card, stat strip, trend sparkline)
RunnerTests/           (+ CalorieEngineTests, ProfileTests, DayDetailTests)
```

## 11. Success Criteria

1. Open the app → Today shows points (unchanged) **plus** estimated calories,
   today's distance and active minutes, and a 7-day trend — no interaction needed.
2. Profile screen shows real height/weight/age/sex from Apple Health, each editable;
   a manual edit persists and overrides Health until cleared.
3. With no weight known, calorie UI shows the "add your weight" card, never a wrong
   number; points and history are unaffected.
4. Tapping a day in History opens a full Day Detail (points, calories, distance,
   time, that day's workouts → workout detail).
5. Calorie numbers are plausible against Apple Health on a real run/walk/ride, and a
   run's steps are not double-counted.
6. All new UI is fully French when the phone is in French; data survives a redeploy.
