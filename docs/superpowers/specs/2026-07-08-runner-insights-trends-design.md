# Runner v1.2 — Insights / Trends (Phase 2)

**Date:** 2026-07-08
**Status:** Approved — implementing
**Owner:** Farid (faridautomatic@gmail.com)
**Parent epic:** v1.2 "History & Trends" (Phase 2 of 4)

## 1. What & Why

Phase 1 added ways to *see* the data (per-type hubs, records, milestones). Phase 2
adds the interpretive **"tell me things"** surface: an Insights screen that turns
the same existing `WorkoutRec` history into trends — how often you train, whether
your distance is climbing, whether your pace is improving.

Everything derives from existing `WorkoutRec` rows via a new pure aggregation
module. **No new sensors, no new persisted fields, no SwiftData migration.**

### Epic sequencing (context)
1. Phase 1 — Activity Detail & Records ✅ (`ActivityStats`, committed `c31f9f0`).
2. **Phase 2 (this spec) — Insights / trends screen.**
3. Phase 3 — Per-run split analytics (deepens WorkoutDetail).
4. Phase 4 — Weekly recap card on Today.

## 2. Architecture

Mirrors the Phase 1 method exactly: a pure, unit-testable aggregation module
(`enum` of static functions over plain value structs, **no SwiftUI / SwiftData
imports**) plus a SwiftUI view that reuses existing DesignSystem components
(`SurfaceCard` / `StatTile` / `MicroLabel`), the segmented-chart idiom from
`ActivityDetailView`, and `ActivityType.accent`.

**Key principle:** `InsightsMath` returns *structured facts and trend enums*, never
finished sentences. The view renders the localized (English/French) plain-language
summary from those facts. This keeps the math locale-independent and fully testable
on numbers.

The module consumes the **existing** `ActivityWorkoutSummary` value type
(defined in `ActivityStats.swift`, mapped from `WorkoutRec` via the existing
`ActivityWorkoutSummary.init(workout:)` in `HistoryView.swift`). No new mapping
layer is introduced.

## 3. Data facts (verified against the codebase)

- `ActivityWorkoutSummary` (Phase 1) carries `id, type, date, distanceMeters,
  movingSeconds, points, calories, splitSeconds, hasRoute` — sufficient for all
  Phase 2 metrics; **no change needed**.
- `HistoryMath.dailySeries(days:lastN:endingAt:calendar:)` establishes the
  `endingAt:` parameter convention for date-pinned aggregation — Phase 2 follows it
  so tests use fixed dates.
- Weeks are **Monday-aligned** everywhere in the app (heatmap, `ActivityStats`
  `weeklyDistance`). Phase 2 reuses the same Monday-start bucketing.
- Pace guard (Phase 1): only sessions with `distanceMeters > 0 && movingSeconds > 0`
  contribute to pace; pace = `movingSeconds / (distanceMeters / 1000)` sec/km.
- DesignSystem: `SurfaceCard`, `StatTile(label:value:accent:)`, `MicroLabel`,
  `Format.km / duration / pace`, colors `rLime / rTeal / rPurple / rOrange /
  rTextSecondary / rBorder / rSurface / rBackground`, `ActivityType.{emoji, accent,
  localizedName, allCases}`.
- `HistoryView` already exposes `navigationDestination(for: ActivityType.self)`
  and computes `LifetimeTotals` (with `perType`) once per render — the most-used
  type default comes free.

## 4. New file: `Runner/Features/History/InsightsMath.swift`

Pure `enum`, no SwiftUI / SwiftData.

```
struct WeeklyInsightPoint: Identifiable      // dense: exactly one per week in range
    weekStart: Date                          // Monday 00:00
    distanceMeters: Double                    // 0 for weeks with no sessions
    avgPaceSecPerKm: Double?                  // nil when no paced session that week
    sessions: Int
    var id: Date { weekStart }

struct PeriodComparison
    distanceMeters: (current: Double, previous: Double)
    sessions:       (current: Int,    previous: Int)
    movingSeconds:  (current: Double, previous: Double)
    weeksPerPeriod: Int
    // computed:
    var distanceDeltaFraction: Double?        // (cur-prev)/prev; nil when prev == 0
    var movingSecondsDeltaFraction: Double?
    var sessionsPerWeekCurrent: Double         // current / weeksPerPeriod
    var sessionsPerWeekPrevious: Double
    var sessionsPerWeekDelta: Double

enum TrendDirection { case improving, steady, declining, insufficientData }

struct InsightSummary
    sessionsPerWeek: Double
    sessionsPerWeekPrevious: Double
    paceTrend: TrendDirection
    paceDeltaSecPerKm: Double?                 // current avg pace − previous avg pace; negative = faster
    distanceTrend: TrendDirection
    hasEnoughData: Bool

enum InsightsMath
    static func weeklySeries(_ summaries: [ActivityWorkoutSummary], type: ActivityType,
                             weeks: Int, endingAt: Date, calendar: Calendar) -> [WeeklyInsightPoint]
    static func periodComparison(_ summaries: [ActivityWorkoutSummary], type: ActivityType,
                                 weeksPerPeriod: Int, endingAt: Date, calendar: Calendar) -> PeriodComparison
    static func summary(_ summaries: [ActivityWorkoutSummary], type: ActivityType,
                        endingAt: Date, calendar: Calendar) -> InsightSummary
```

### 4.1 `weeklySeries`
- Produces a **dense** array of exactly `weeks` entries ending with the week that
  contains `endingAt`, one per Monday-aligned week, oldest → newest.
- Each entry sums that type's sessions falling in that week: `distanceMeters`,
  `sessions` count, and `avgPaceSecPerKm` = (sum movingSeconds of paced sessions) /
  (sum km of paced sessions), or `nil` if the week has no paced session.
- Weeks with no sessions appear with `distanceMeters = 0`, `sessions = 0`,
  `avgPaceSecPerKm = nil` (stable x-axis; the pace line simply skips them).

### 4.2 `periodComparison`
- **Current** period = the last `weeksPerPeriod` weeks up to and including the week
  of `endingAt`. **Previous** period = the `weeksPerPeriod` weeks immediately before
  that. Boundary is Monday-aligned; a session exactly on a Monday 00:00 belongs to
  that week.
- Sums this type's distance, sessions, and movingSeconds in each period.
- Delta fractions are `nil` when the previous value is 0 (avoid divide-by-zero;
  the view shows "new" rather than a percentage).

### 4.3 `summary`
- `sessionsPerWeek` / `sessionsPerWeekPrevious` from a 4-week `periodComparison`.
- **paceTrend** from current-4-week vs previous-4-week average pace (weighted by km,
  same as `periodComparison` weeks):
  - `insufficientData` if either period has no paced session.
  - `improving` if current is **faster** by > 3 s/km (delta < −3).
  - `declining` if current is **slower** by > 3 s/km (delta > +3).
  - `steady` otherwise. `paceDeltaSecPerKm` carries the signed value.
- **distanceTrend** from the two periods' total distance:
  - `insufficientData` if the previous period has 0 distance.
  - `improving` if `distanceDeltaFraction > +0.10`, `declining` if `< −0.10`,
    else `steady`.
- **hasEnoughData** = the current 4-week period has ≥ 1 session. Drives the summary
  card's empty state.

All thresholds (3 s/km, 10%, 4-week period, 12-week chart window) are the only
tuned constants; keep them as named `private` constants for clarity.

## 5. New file: `Runner/Features/History/InsightsView.swift`

`ScrollView` on `Color.rBackground`, `navigationTitle("Insights")`,
`navigationBarTitleDisplayMode(.inline)`. `@Query(sort: \WorkoutRec.start, order:
.reverse)` for workouts, mapped once to `[ActivityWorkoutSummary]`.

`init(initialType: ActivityType)`; `@State private var selectedType` seeded from it.

Top-to-bottom:

1. **Type selector** — segmented `Picker` bound to `selectedType`, one tag per
   `ActivityType.allCases` (label = `type.emoji + " " + type.localizedName`).
   Scopes the entire screen.
2. **Summary card** — `SurfaceCard` containing 1–3 sentences built from
   `InsightsMath.summary(...)`:
   - Frequency: `"You're {running/walking/biking} {sessionsPerWeek, 1 dp}× per week"`,
     plus `", up from {prev}"` / `", down from {prev}"` when `sessionsPerWeekPrevious
     > 0`.
   - Pace: `improving` → "Pace is improving — {|delta|}s/km faster than the previous
     4 weeks."; `declining` → "…{|delta|}s/km slower…"; `steady` → "Pace is holding
     steady."; `insufficientData` → omit the pace line.
   - When `hasEnoughData == false`, replace the whole card body with
     "Not enough data yet — keep at it!".
   The activity verb ("running/walking/biking") is chosen per `ActivityType` via a
   localized helper, not string-concatenated, so French reads naturally.
3. **Delta tiles** — a `MicroLabel("vs previous 4 weeks")` + 3 `StatTile`s from
   `periodComparison(weeksPerPeriod: 4)`: Distance (▲/▼ + %), Sessions (▲/▼ +
   per-week delta, 1 dp), Time (▲/▼ + %). Arrow/color: up = `rLime`, down =
   `rOrange`, flat/nil = `rTextSecondary`. When a delta fraction is `nil` (no prior
   data) show "new".
4. **Weekly distance chart** — `MicroLabel("Distance by week")`, `Chart` of
   `weeklySeries(weeks: 12)` `BarMark(x: weekStart unit .weekOfYear, y: km)`
   `.foregroundStyle(selectedType.accent)`, height 150, trailing y-axis. Mirrors
   `ActivityDetailView.distanceChart`.
5. **Pace chart** — `MicroLabel("Pace by week (lower = faster)")`, `Chart` of the
   same series filtered to weeks with non-nil pace: `LineMark` + `PointMark`
   (x: weekStart, y: pace sec/km) `.foregroundStyle(selectedType.accent)`, height
   150, trailing y-axis. When fewer than 2 paced weeks exist, show a
   `SurfaceCard` "Not enough pace data yet" placeholder instead of the chart.

No segmented Week/Month range toggle here (the window is fixed at 12 weeks); the
type selector is the only control.

## 6. Entry point in `HistoryView`

- Add a route value `struct InsightsRoute: Hashable { let initialType: ActivityType }`.
- Add `.navigationDestination(for: InsightsRoute.self) { InsightsView(initialType:
  $0.initialType) }` alongside the existing destinations.
- Add an **Insights entry card** directly under the heatmap (before `chartSection`):
  a full-width tappable `SurfaceCard`-style row — leading icon (📈 / `chart.line.uptrend.xyaxis`),
  title "Insights", subtitle "Trends, pace & consistency", trailing chevron, subtle
  `rLime` accent. Wrapped in `NavigationLink(value: InsightsRoute(initialType:
  mostUsedType))`, `.buttonStyle(.plain)`.
- `mostUsedType` = the `ActivityType` with the greatest `perType.workouts` in the
  already-computed `LifetimeTotals`; ties broken by `ActivityType.allCases` order;
  defaults to `.run` when there is no data.

## 7. Testing — `RunnerTests/InsightsMathTests.swift`

Pure tests, no SwiftData, fixed `Calendar` (Monday-first) and pinned `endingAt`:

- `weeklySeries` returns exactly `weeks` dense entries, oldest→newest, last entry is
  the week of `endingAt`.
- Empty weeks present with `distanceMeters == 0`, `sessions == 0`, `avgPaceSecPerKm
  == nil`.
- Per-week distance/sessions sums correct; per-week avg pace is km-weighted and
  excludes zero-distance/zero-time sessions.
- Only the selected `type` contributes (mixed-type input filtered).
- `periodComparison`: current vs previous split at the 4-week boundary; a session on
  the boundary Monday lands in the correct period; sums correct; `distanceDeltaFraction
  == nil` when previous == 0.
- `summary`: `sessionsPerWeek` math; pace `improving` when current km-weighted avg is
  faster by > 3 s/km; `declining` when slower by > 3; `steady` within ±3;
  `insufficientData` when a period has no paced session; distance trend at the ±10%
  thresholds; `hasEnoughData` true/false.
- Empty input → `insufficientData` / zeros / no crash.
- DST-safe weekly bucketing (a range spanning a DST change still yields `weeks`
  entries with correct Monday starts).

## 8. i18n

All new UI strings via `String(localized:)` with French added to
`Localizable.xcstrings`. New keys (English → French intent):

- "Insights" → *Analyses*
- "Trends, pace & consistency" → *Tendances, allure et régularité*
- "vs previous 4 weeks" → *vs 4 semaines précédentes*
- "Distance by week" → *Distance par semaine*
- "Pace by week (lower = faster)" → *Allure par semaine (plus bas = plus rapide)*
- "Not enough data yet — keep at it!" / "Not enough pace data yet"
- Frequency sentence per type ("You're running/walking/biking %@× per week"),
  ", up from %@" / ", down from %@"
- "Pace is improving — %@ faster than the previous 4 weeks." / "…%@ slower…" /
  "Pace is holding steady."
- "new" (delta with no prior data)

Numbers/dates via existing `Format` and system-locale formatters. Sentences are
assembled from localized fragments/format strings — never English-concatenated —
so French grammar is correct.

## 9. Build / registration

XcodeGen-generated project. New sources under `Runner/…` and `RunnerTests/…` are
picked up by `xcodegen generate`. Verify with `xcodebuild ... build test` on an
iPhone simulator before calling Phase 2 done.

## 10. Out of scope (Phase 2)

Per-run split analytics (Phase 3), weekly recap card on Today (Phase 4). No changes
to recording, the points engine, the calorie engine, or the data model.

## 11. Success criteria

1. History shows a prominent Insights entry card under the heatmap that pushes the
   Insights screen with the most-used activity type preselected.
2. The type selector re-scopes the whole screen (summary, tiles, both charts).
3. The summary card states frequency and pace trends in plain English/French, and
   degrades gracefully when data is thin.
4. Delta tiles compare the last 4 weeks to the prior 4 with correct arrows/percentages.
5. Weekly distance and pace-over-time charts render 12 weeks in the type's accent.
6. All `InsightsMath` math is covered by passing unit tests with no SwiftData.
7. Full French UI when the phone is in French.
8. No SwiftData migration; existing data renders correctly; build + tests green.
