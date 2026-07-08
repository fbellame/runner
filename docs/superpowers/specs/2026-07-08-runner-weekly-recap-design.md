# Runner v1.2 — Phase 4: Weekly Recap Card on Today

**Date:** 2026-07-08
**Branch:** `runner-v1`
**Epic:** v1.2 History & Trends (Phase 4 of 4 — final phase)

## Goal

Add an automatic "this week" recap card to the Today screen that summarizes the
current Monday-aligned week: total points (with a fair vs-last-week comparison),
total distance, session count, the week's best run, and gold-day count. It rolls to
a fresh week every Monday with no user action.

No new sensors, no recording changes, no SwiftData migration. Everything derives
from the existing `DayLedger` (per-day points, gold flag) and `WorkoutRec`
(individual workouts for distance / sessions / best run), already `@Query`-ed by
`TodayView`.

## Design decisions (confirmed)

- **Behavior:** live current week (Mon → now), always shown when there's activity,
  rolls each Monday. No dismiss/persistence state.
- **Best run:** the single workout with the greatest distance this week.
- **Metrics shown:** total points + vs-last-week delta, total distance, session
  count, best run, gold-day count.
- **Fair comparison:** the "vs last week" delta compares the **same portion** of
  last week, not last week's full total. The current window is shifted back exactly
  7 days for the previous-period figure, so mid-week the comparison stays honest
  (Mon–Wed vs last Mon–Wed) instead of always showing a decline.

## Architecture

Follows the established Phase 1–3 pattern: a pure, Foundation-only aggregation
module returning structured facts, consumed by a SwiftUI card that reuses
DesignSystem components. Mirrors `InsightsMath` (Monday alignment, `endingAt`/`now`
date pinning for testability).

### Pure module — `Runner/Features/Today/WeeklyRecapMath.swift`

Foundation only. No SwiftUI / SwiftData.

```swift
struct RecapLedgerDay {          // plain input; view maps DayLedger -> this
    let date: Date               // the ledger's day (start-of-day)
    let totalPoints: Int
    let isGold: Bool
}

struct BestRun: Equatable {
    let type: ActivityType
    let distanceMeters: Double
    let date: Date
}

struct WeeklyRecap: Equatable {
    let points: Int
    let pointsPrevious: Int
    let pointsDeltaFraction: Double?   // nil when pointsPrevious == 0
    let distanceMeters: Double
    let sessions: Int
    let goldDays: Int
    let bestRun: BestRun?
    var hasActivity: Bool { points > 0 || sessions > 0 || distanceMeters > 0 }
}

enum WeeklyRecapMath {
    static func recap(ledgers: [RecapLedgerDay],
                      workouts: [ActivityWorkoutSummary],
                      now: Date,
                      calendar: Calendar) -> WeeklyRecap
}
```

**Windows** (using a private `mondayStart(for:calendar:)` helper identical to
`InsightsMath`'s `(weekday + 5) % 7` convention):

- `currentStart = mondayStart(now)`; `today0 = startOfDay(now)`.
- **Current ledger window** (whole days): `date in [currentStart, today0]`.
- **Previous ledger window** (shifted −7d): `date in [currentStart − 7d, today0 − 7d]`.
- **Current workout window**: `date >= currentStart && date <= now`.

**Computation:**
- `points` = Σ `totalPoints` of ledgers in the current window.
- `pointsPrevious` = Σ `totalPoints` of ledgers in the previous window.
- `pointsDeltaFraction` = `(points − pointsPrevious) / pointsPrevious`, or `nil`
  when `pointsPrevious == 0`.
- `goldDays` = count of `isGold` ledgers in the **current** window only.
- `distanceMeters` = Σ workout `distanceMeters` in the current workout window.
- `sessions` = count of workouts in the current workout window.
- `bestRun` = the current-week workout with max `distanceMeters` (ties → earliest
  by `date`); `nil` when no workouts this week.

Notes: daily ledgers are whole-day buckets, so today's in-progress ledger is
compared against last week's same-weekday full ledger — an inherent, acceptable
imprecision. Workout ranges use the exact `now` timestamp.

### View — `TodayView`

Add a `weeklyRecapCard` computed view, inserted **immediately above** `trendCard`
in the main `VStack` (grouping the zoomed-out content; it is a distinct lens from
the rolling daily "Last 7 days" chart). Build the recap once from the existing
`@Query` data:

```swift
let recap = WeeklyRecapMath.recap(
    ledgers: ledgers.map { RecapLedgerDay(date: $0.date, totalPoints: $0.totalPoints, isGold: $0.isGold) },
    workouts: workouts.map(ActivityWorkoutSummary.init(workout:)),
    now: .now, calendar: .current)
```

Render only when `recap.hasActivity` (no empty card for a fresh week).

`SurfaceCard` layout, matching the approved mockup:
- `MicroLabel("This week")`.
- Headline row: points value (bold, rounded, white) + a delta chip: `▲ NN%`
  (`rLime`), `▼ NN%` (`rOrange`), flat `0%` (`rTextSecondary`), or `new`
  (`rTextSecondary`) when `pointsDeltaFraction == nil`. Chip labelled "vs last week".
- Secondary row: distance (`Format.km`) and session count.
- Best-run line: `"<emoji> <km> · <weekday>"` (e.g. `🏃 8.2 km · Tue`), hidden when
  `bestRun == nil`. Weekday via `date.formatted(.dateTime.weekday(.abbreviated))`.
- Gold-days line: `"🥇 N gold days"` (plural-aware), hidden when `goldDays == 0`.

Reuse existing helpers (`StatTile` or the local `statTile` pattern, `MicroLabel`,
`Format`, `ActivityType.emoji/.accent`). Keep styling consistent with the
surrounding cards.

## i18n

New keys in `Runner/Resources/Localizable.xcstrings` with French. `%@`/`%lld`
placeholders; sentences assembled from localized fragments (never
English-concatenated). Gold-days uses xcstrings **plural variations** (`one`/`other`
in English, `one`/`other` in French):

| English | French |
|---|---|
| This week | Cette semaine |
| vs last week | vs semaine dernière |
| new | nouveau |
| %lld sessions | %lld séances |
| Best run | Meilleure sortie |
| %lld gold days (plural: one → "%lld gold day") | %lld jours en or (one → "%lld jour en or") |

(Final wording refined for naturalness during implementation.)

## Testing — `RunnerTests/WeeklyRecapMathTests.swift`

Swift Testing (`import Testing`, `@Test`, `#expect`), fixed Calendar
(America/Toronto, `firstWeekday = 2`) and a pinned `now`, mirroring
`InsightsMathTests`. Cases:

1. Empty inputs → all zero, `bestRun == nil`, `pointsDeltaFraction == nil`,
   `hasActivity == false`, no crash.
2. Current-week sums (points, distance, sessions) correct and **exclude** prior
   weeks and any future-dated entries.
3. Monday boundary: a ledger/workout at Monday 00:00 is in the current week; the
   preceding Sunday belongs to the previous week (Monday-first).
4. Best run = max distance among current-week workouts; returns its `type` + `date`;
   tie resolves to the earliest date; a bigger run last week is ignored.
5. Previous-window points come from the −7d shifted range; `pointsDeltaFraction`
   computed correctly; `nil` when `pointsPrevious == 0`.
6. Gold-days counts only current-week `isGold` ledgers.
7. DST spring-forward week keeps correct Monday alignment (March 2026).

## Success criteria

- `WeeklyRecapMath.recap` is pure and unit-tested (≥ 7 substantive cases).
- Today shows the recap card above the 7-day trend when the current week has
  activity; hidden otherwise.
- vs-last-week uses the same-portion (−7d) comparison.
- French present for all new strings; gold-days pluralizes correctly.
- `xcodegen generate` clean; `xcodebuild … build test` green on an iPhone sim.

## Out of scope

- Notifications / a dedicated "recap" screen (card only).
- Historical week-by-week browsing (that's the Insights screen, Phase 2).
- Dismiss/persistence or Monday-retrospective behavior (explicitly not chosen).
- Changing point/calorie formulas.
