# Runner v1.2 — Activity Detail & Records (Phase 1)

**Date:** 2026-07-08
**Status:** Approved — implementing
**Owner:** Farid (faridautomatic@gmail.com)
**Parent epic:** v1.2 "History & Trends" (Phase 1 of 4)

## 1. What & Why

The app already shows a heatmap, points charts, a current-records card, and a
7-day trend. This phase adds **more ways to see the data that already exists** —
no new sensors, no new recording, no new persisted fields. It turns the flat
workout list into three real "sport profiles" and makes records a story with
dates and milestones instead of a snapshot.

Everything derives from existing `WorkoutRec` + `DayLedger` rows. **No SwiftData
schema change, no migration.**

### Epic sequencing (context)
1. **Phase 1 (this spec) — Activity Detail & Records.** Foundational aggregation layer.
2. Phase 2 — Insights/trends screen (reuses Phase 1 aggregates).
3. Phase 3 — Per-run split analytics (deepens WorkoutDetail).
4. Phase 4 — Weekly recap card on Today.

## 2. Architecture

A pure, unit-testable aggregation module plus view additions inside History.
Mirrors the existing `HistoryMath` pattern: a plain `enum` of static functions
over plain value structs, no SwiftUI / SwiftData imports, so all math is tested
without a store.

### New file: `Runner/Features/History/ActivityStats.swift`

```
struct WorkoutSummary            // plain value type the views map WorkoutRec into
    type: ActivityType · date: Date · distanceMeters: Double
    movingSeconds: Double · points: Int · calories: Double · splitSeconds: [Double]

struct TypeStats
    sessions: Int · totalDistanceMeters · totalMovingSeconds · totalCalories: Double
    totalPoints: Int · bestPaceSecPerKm: Double? · avgPaceSecPerKm: Double?
    longestDistanceMeters: Double · weeklyDistance: [(weekStart: Date, meters: Double)]

struct LifetimeTotals
    distanceMeters · movingSeconds · calories: Double · workouts: Int · routesPainted: Int
    perType: [ActivityType: (distanceMeters: Double, workouts: Int)]

struct PersonalRecord           // one record row
    kind: RecordKind · value: Double · workoutID: UUID? · date: Date?

struct Milestone
    kind: MilestoneKind · threshold: Double · earned: Bool
    progress: Double            // 0…1 toward threshold (for the single "next" badge)

enum ActivityStats
    static func typeStats(_ summaries: [WorkoutSummary], type: ActivityType, calendar: Calendar) -> TypeStats
    static func lifetimeTotals(_ summaries: [WorkoutSummary]) -> LifetimeTotals
    static func typeRecords(_ summaries: [WorkoutSummary], type: ActivityType) -> [PersonalRecord]
    static func milestones(_ totals: LifetimeTotals) -> [Milestone]
```

Guards: pace is computed only over sessions with `distanceMeters > 0 &&
movingSeconds > 0`. Empty inputs yield zeros / `nil`, never a crash or division
by zero.

## 3. Data facts (verified against the codebase)

- `WorkoutRec` already carries `typeRaw, start, end, movingSeconds,
  distanceMeters, points, calories, splitSeconds, routeData`.
- `splitSeconds` holds **per-completed-kilometer durations** (from
  `WorkoutRecorder`: `movingSeconds - lastSplitMovingSeconds` per whole km; the
  trailing partial km is not included). This makes 1 km / 5 km records clean.
- `DayLedger` carries `totalPoints, streakAfter` → best day / best streak.
- `ActivityType` (`Theme.swift`): `.run/.walk/.bike`, with `emoji`, `accent`
  (run teal, walk lime, bike purple), `localizedName`.
- `Format.km/duration/pace` and `SurfaceCard/StatTile/MicroLabel/GlowNumber`
  design components already exist and must be reused.

## 4. Records (exact definitions)

| Record | Rule | Tappable → |
|---|---|---|
| Longest (per type) | `max(distanceMeters)` for that type | holding workout |
| Fastest 1 km (per type) | `min` single element of `splitSeconds` across the type | holding workout |
| Fastest 5 km (per type) | `min` rolling sum of 5 consecutive splits within one workout; **nil** if no workout has ≥5 splits | holding workout |
| Best avg pace (per type) | `min(movingSeconds / km)` over sessions with `distanceMeters ≥ 1000 m` (floor blocks a 200 m sprint winning) | holding workout |
| Best day | `max(DayLedger.totalPoints)` | — (non-tappable) |
| Best streak | `max(DayLedger.streakAfter)` | — (non-tappable) |

Each `PersonalRecord` stores the holding `workoutID` + `date` so History's
Records card and the type hub can navigate to the exact workout.

## 5. Milestones

Derived purely from `LifetimeTotals`:

- **Total-distance** badges: 10 / 25 / 50 / 100 / 250 / 500 / 1000 km.
- **Workout-count** badges: 10 / 25 / 50 / 100 workouts.

Earned badges glow lime; the single next-unearned badge of each track shows a
progress bar (`progress` 0…1). Rendered as a horizontal-scroll chip row.

## 6. UI — new/changed surfaces inside History

`HistoryView` gains sections, in this top-to-bottom order:

1. Heatmap *(existing)*
2. Points chart *(existing)*
3. **Lifetime totals card** *(new)* — `StatTile`s: total km · total time · total calories · workouts.
4. **Activity-type row** *(new)* — three tappable accent cards (Run / Walk / Bike), each "N sessions · X km", accent-colored. Tap → `ActivityDetailView(type:)`.
5. **Records card** *(enhanced)* — existing rows gain the date set and become tappable → the record-holding workout via `WorkoutDetailView`; add "Fastest 1 km." Best-day / best-streak stay (ledger-based, non-tappable).
6. **Milestones row** *(new)* — horizontal badge chips.
7. Workouts list *(existing)*

Views map `[WorkoutRec]` (already `@Query`-ed in `HistoryView`) → `[WorkoutSummary]`
once and pass into `ActivityStats`.

### New screen: `Runner/Features/History/ActivityDetailView.swift`

Pushed via `navigationDestination` when a type card is tapped. `ActivityType`
is `Hashable` (String raw) so it can be the navigation value directly.

- Accent header: `type.emoji` + `type.localizedName`.
- Stat tiles: sessions · total distance · total time · total calories.
- Pace tiles: best pace · average pace.
- Weekly distance mini-chart (accent bars) with a Week/Month segmented toggle
  matching the existing chart idiom.
- This type's records (longest, fastest 1 km, fastest 5 km when available, best
  avg pace) — each tappable → `WorkoutDetailView`.
- Recent sessions of this type — reuse the existing workout-row layout.

## 7. Testing — `RunnerTests/ActivityStatsTests.swift`

Pure tests, no SwiftData:

- Totals summation across mixed types; per-type distance/count.
- Best / avg pace with zero-distance and zero-time sessions filtered out.
- Best avg pace 1 km floor (a fast 200 m session must not win).
- Longest per type.
- Fastest 1 km across multiple workouts.
- Fastest 5 km rolling window; the `<5 splits → nil` case; a 5-split and a
  7-split workout choosing the right window.
- Milestone thresholds just-below / at / just-above; `earned` and `progress`.
- Empty input → all zeros / nil.
- Weekly bucketing is DST-safe (uses `Calendar`, week starts Monday like the heatmap).

## 8. i18n

All new strings via `String(localized:)` with French added to
`Localizable.xcstrings` (*plus long, plus rapide, records, total / à vie,
sessions, jalons*). Dates via system-locale formatters; distance / time / pace
via existing `Format`.

## 9. Build / registration

Project is XcodeGen-generated. New source files under `Runner/…` and
`RunnerTests/…` are picked up by `xcodegen generate` (see repo convention in
recent commits). Build + run the test suite before calling Phase 1 done.

## 10. Out of scope (Phase 1)

Insights/trends screen (Phase 2), per-run split analytics (Phase 3), weekly
recap card (Phase 4). No changes to recording, the points engine, or the data
model.

## 11. Success criteria

1. History shows lifetime totals, three tappable activity-type cards, enhanced
   dated/tappable records, and a milestones row.
2. Tapping Run / Walk / Bike opens a type hub with totals, pace, a weekly
   distance chart, that type's records, and recent sessions.
3. Tapping a record navigates to the exact workout that holds it.
4. All `ActivityStats` math is covered by passing unit tests with no SwiftData.
5. Full French UI when the phone is in French.
6. No SwiftData migration; existing data renders correctly.
