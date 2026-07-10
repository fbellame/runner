# Runner — Activity Hubs (v1.6)

**Date:** 2026-07-10
**Status:** Approved (Farid, 2026-07-10)
**Branch:** `activity-hubs` (off `main`, independent of the open v1.5 PR #4)

## Goal

Evolve the Insights screen into three per-activity **hubs** (Run / Walk / Bixi)
that answer Farid's real questions: *am I improving over the long term, how
does this year compare to last, am I consistent, and what are my bests?*
Motivation profile: beating past self, milestones, seeing the story.

First sub-project of the v1.6–v1.8 engagement epic (A: Trophy Room,
B: Monthly Wrapped, C: Activity Hubs — C was chosen first).

## Non-goals

- No new milestones/badges system (that's Trophy Room, sub-project A).
- No monthly wrapped recap (sub-project B).
- No navigation changes: hubs live where Insights lives today, behind the
  same segmented Run/Walk/Bixi picker.
- No money-saved estimate for Bixi (too assumption-heavy).
- No new data layer: the SwiftData `WorkoutRec` query already loads all
  workouts and full HealthKit history is already backfilled (v1.3/v1.4).

## Approach

Stacked blocks + range toggle (chosen over a single global time selector,
which fits neither year-over-year nor records). `InsightsView` becomes a thin
shell composing per-block subviews. All new logic is pure math in
`Features/History/HubMath.swift`, unit-tested, following the
`InsightsMath` / `ActivityStats` pattern (pure functions over
`[ActivityWorkoutSummary]`, explicit `Date`/`Calendar` parameters).

## Hub layout (top to bottom, per selected activity)

1. **Summary sentence + momentum** — existing frequency/pace sentence and
   4-vs-4-week delta tiles, unchanged.
2. **Year in review** — YTD totals vs the *same date range* last year, plus a
   12-month bar chart of the current calendar year with last year's months as
   ghost bars behind.
3. **Progression charts** — existing distance and pace charts gain a
   `12W / 1Y / All` range toggle (weekly buckets for 12W, monthly for 1Y and
   All).
4. **Activity-specific block**
   - *Run:* best efforts this year vs all-time (fastest 1 km, fastest 5 km,
     best avg pace) — is 2026-me beating all-time-me?
   - *Bixi:* rides + CO₂ avoided, YTD and lifetime, with the tangible
     equivalence "≈ N km not driven" (`co2Grams / CO2Estimator.carGramsPerKm`).
   - *Walk:* volume framing — hours, km, sessions, YTD and lifetime.
5. **Consistency** — sessions-per-week sparkline over the last 52 weeks,
   longest streak of consecutive active weeks (all history), current active
   week streak, and a gap callout ("Last run: 12 days ago") when the gap
   exceeds 7 days.
6. **Records** — existing per-type PRs (`ActivityStats.typeRecords`) rendered
   inside the hub, using a `RecordRow` component extracted from
   `ActivityDetailView` (shared, not duplicated).

## New pure math (`HubMath.swift`)

```swift
struct YearInReview {
    let year: Int
    let distanceMeters: (current: Double, previous: Double)
    let sessions: (current: Int, previous: Int)
    let movingSeconds: (current: Double, previous: Double)
    let co2SavedGrams: (current: Double, previous: Double)
    let isFirstTrackedYear: Bool      // no summaries before Jan 1 of `year`
    // delta helpers mirroring PeriodComparison
}

struct MonthlyInsightPoint: Identifiable {
    let monthStart: Date
    let distanceMeters: Double
    let avgPaceSecPerKm: Double?      // nil when no paced distance
    let sessions: Int
}

struct YearMonthPoint: Identifiable { // ghost-bar chart
    let monthIndex: Int               // 1...12
    let currentMeters: Double
    let previousMeters: Double
}

struct ConsistencyStats {
    let longestWeekStreak: Int        // consecutive active weeks, all history
    let currentWeekStreak: Int        // ending at current week (grace: an
                                      // inactive current week counts from last week)
    let daysSinceLast: Int?           // nil if the activity has never happened
}

enum HubMath {
    static func yearInReview(_ s: [ActivityWorkoutSummary], type: ActivityType,
                             asOf: Date, calendar: Calendar) -> YearInReview
    static func monthlySeries(_ s: [ActivityWorkoutSummary], type: ActivityType,
                              months: Int, endingAt: Date,
                              calendar: Calendar) -> [MonthlyInsightPoint]
    static func yearMonthlyComparison(_ s: [ActivityWorkoutSummary],
                                      type: ActivityType, year: Int,
                                      calendar: Calendar) -> [YearMonthPoint]
    static func consistency(_ s: [ActivityWorkoutSummary], type: ActivityType,
                            asOf: Date, calendar: Calendar) -> ConsistencyStats
    static func monthsSpanningAll(_ s: [ActivityWorkoutSummary],
                                  endingAt: Date, calendar: Calendar) -> Int
}
```

Semantics:

- **Same-date-range YoY:** current period is Jan 1 of `asOf`'s year through
  `asOf` (inclusive); previous period is Jan 1 of the prior year through
  `calendar.date(byAdding: .year, value: -1, to: asOf)` (Feb 29 maps to
  Feb 28 via Calendar, accepted). Workouts filtered by `date >= start &&
  date <= end` on the current side, same shape on the previous side.
- **Month bucketing** mirrors `weeklySeries`: fixed bucket list first (so
  empty months render as zero bars), then fold summaries in. Month start =
  `calendar.dateInterval(of: .month, for:)`. Pace = paced seconds / paced km,
  nil when no paced distance — same rule as `WeekBucket`.
- **Week streaks** reuse the Monday-start convention (`mondayStart`).
  Active week = ≥1 session of that type. Longest streak scans all history;
  current streak counts back from the current week, tolerating an inactive
  *current* week (you haven't failed this week until it's over).
- **All range** = `monthlySeries` with `months = monthsSpanningAll(...)`
  (clamped to ≥12).
- **Run best-efforts comparison** needs no new math:
  `ActivityStats.typeRecords` runs once on all summaries and once on
  summaries filtered to the current year.

## Views

- `InsightsView` stays the entry point (same `initialType` init, same
  segmented picker) and becomes a composition shell.
- New files in `Features/History/`: `YearInReviewBlock.swift`,
  `HubProgressionCharts.swift` (charts + `12W / 1Y / All` toggle),
  `ActivitySpecificBlock.swift`, `ConsistencyBlock.swift`,
  `HubRecordsBlock.swift`, and shared `RecordRow.swift` (extracted from
  `ActivityDetailView`; both call sites use it).
- Existing design system throughout: `SurfaceCard`, `StatTile`, `MicroLabel`,
  `type.accent`, `Color.rBackground`. Ghost bars: previous-year `BarMark`
  in `type.accent.opacity(0.25)` behind current-year bars.
- `ActivityDetailView` keeps its totals/records/recent-sessions role; only
  the record-row rendering moves to the shared component.

## Empty / edge states

- **First tracked year:** year block shows current YTD totals with a
  "Your first tracked year 🎉" caption instead of a broken comparison.
- **No data at all for a type:** blocks show the existing
  "Not enough data yet — keep at it!" card style; the hub keeps its shape.
- **Gap callout** only renders when `daysSinceLast > 7` (no nagging).
- **Pace chart** in 1Y/All hides months with nil pace, same as weekly today.

## Localization

All new strings in English and French via `Localizable.xcstrings`, matching
the existing tone (short, warm, emoji-friendly).

## Testing

TDD on `HubMathTests.swift`:

- YoY date-range clamping (mid-year asOf, Jan 1 asOf, Dec 31 asOf, leap day).
- `isFirstTrackedYear` on/off.
- Month bucketing across year boundaries; empty months present as zeros.
- Ghost-bar comparison aligns months by index, not by date.
- Streaks: single week, gap breaks streak, inactive current week grace,
  never-active type (`daysSinceLast == nil`).
- `monthsSpanningAll` clamps to 12 and spans multi-year data.

Views stay thin (no view tests, per house style). Full suite must stay green.
