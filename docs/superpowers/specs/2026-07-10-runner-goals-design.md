# Runner v1.9 — Goals (weekly consistency + per-activity distance)

**Date:** 2026-07-10
**Status:** Approved design, pending implementation plan

## Summary

A forward-looking goals layer on top of the existing daily-points/gold-day
mechanic. Two goal kinds:

1. **Weekly consistency goal** — "hit your daily points goal N days this week"
   (N = 1–7). Progress on Today, weekly streak, celebration on completion,
   trophy badges.
2. **Per-activity weekly distance goals** — optional km/week per activity
   (run / walk / bike). Set and shown in each activity hub
   (`ActivityDetailView`), with a compact rollup on Today.

Everything is **silent and in-app only**: no notifications, no permission
prompts. This matches the app's fully-silent auto-walk philosophy.

Ships in two phases; phase 1 is independently shippable.

## Decisions (from brainstorm)

| Question | Decision |
|---|---|
| Direction | Goals & training targets (v1.9) |
| Shape | Mix: weekly consistency + per-activity volume |
| Nudges | Silent, in-app only — no notifications |
| Per-activity metric | Distance per week (km), one number per activity |
| Approach | Two-phase epic on a pure derivation engine (`GoalsMath`), following the `WrappedMath` pattern |

## Data & settings

### Weekly consistency target
- `weeklyGoldTarget: Int` (range 1...7, default 3) on `AppModel`,
  UserDefaults-backed, same pattern as `dailyGoal`.
- Settings UI: a Stepper in the existing "Daily goal" section of
  `SettingsView`, directly below the daily-goal stepper.

### Historical honesty (snapshot)
- Add `weeklyTargetAtThatTime: Int` to `DayLedger`
  (`Runner/Core/Store/Models.swift`) with a **migration-safe inline default**
  (existing pattern from the v1.x migrations), written by `LedgerBuilder`
  alongside `goalAtThatTime`.
- A past week is judged by the snapshot of its **latest ledgered day** in that
  week. Raising the target later never rewrites history — same philosophy as
  the daily `goalAtThatTime`.

### Per-activity distance goals (phase 2)
- Optional `Double` km/week per `ActivityType` (`.run`, `.walk`, `.bike`),
  UserDefaults-backed on `AppModel` (e.g. keys `weeklyDistanceGoal.run`).
  `nil` = no goal set for that activity.
- **No historical snapshots.** Only the current week is displayed, so judging
  against the current value is honest and avoids SwiftData schema growth.

## Engine — `GoalsMath` (pure)

Lives in `Runner/Features/Shared/GoalsMath.swift` (it feeds both Today and
the activity hubs). Pure functions, injected `Calendar`, no side effects —
the `WrappedMath` template.

**Inputs:** day-ledger projections (date, isGold, weeklyTargetAtThatTime),
workout summaries (for per-activity distance), current per-activity goals,
`Calendar`.

**Outputs:**
- **Current week:** gold days so far vs target; seven per-day dot states
  (gold / not gold / future).
- **Weekly streak:** consecutive completed weeks ending at the most recent
  fully judged week (current week counts once completed).
- **Per-activity (phase 2):** distance so far this week vs goal per activity
  with a goal set, as a fraction for the ring.

### Shared week helper (targeted refactor)
Monday-week-start bucketing (`(weekday + 5) % 7`) is currently duplicated
privately in `WeeklyRecapMath`, `ActivityStats`, `HubMath`, and
`InsightsMath`. Extract one shared helper
(`Runner/Features/Shared/WeekMath.swift`) and point all four call sites plus
`GoalsMath` at it. No behavior change; covered by the existing tests of those
four engines.

## UI surfaces

### Today (phase 1)
- A **weekly-goal row** inside/under `pointsBlock` in `TodayView`: seven
  day-dots (gold-filled for gold days, hollow for missed, dimmed for future),
  a label like "3 of 4 this week", and the weekly streak (e.g. "5-week
  streak") when ≥ 2.
- **Celebration:** `CelebrationBurst` + `Haptics.goalReached()` fire on the
  week's false→true completion transition, same mechanism as the daily gold
  celebration (guarded so daily and weekly bursts don't double-fire in the
  same render).

### Activity hub (phase 2)
- In `ActivityDetailView` header/totals area: a **goal ring** (distance this
  week / goal) when a goal is set, and a "Set weekly goal" affordance opening
  a small sheet with a stepper (km, sensible per-activity step). Editing and
  clearing the goal happen in the same sheet. No separate Settings entry.

### Today rollup (phase 2)
- A compact row of per-activity **mini-rings** (icon + ring + "12/15 km"),
  shown only for activities with a goal set. Slotted after the weekly recap
  card, the same insertion pattern used for the Wrapped banner.

### Localization
All new strings added to `Localizable.xcstrings` in English and French.

## Trophies (phase 1)

New badge category in `TrophyMath` (recomputed chronologically from
summaries + ledger projections, no new persistence beyond the existing
`TrophySeenStore` seen-IDs pattern):

- **First weekly goal met**
- **4-week streak**
- **12-week streak**

Weekly-goal completions are derived by `GoalsMath` over history, so past
weeks that already met the target mint badges retroactively on first run —
consistent with how Trophy Room backfilled.

## Error handling & edge cases

- **Target changed mid-week:** the week is judged by the snapshot of its
  latest ledgered day; the Today row always shows the live target for the
  current week.
- **Weeks with no ledger days:** streak-breaking (a week with zero gold days
  cannot meet any target ≥ 1).
- **Timezone/DST:** injected `Calendar` everywhere; tests pin
  Gregorian/Toronto like `WrappedMathTests`.
- **Distance-less workouts (phase 2):** contribute 0 km to the ring, same as
  everywhere else distance is summed.
- **No goal set (phase 2):** activity shows no ring and no rollup entry —
  goals are opt-in per activity.

## Testing

- `GoalsMathTests` in `RunnerTests`, Swift Testing (`@Test` / `#expect`),
  fixed calendar, fixture helpers copied from the `WrappedMathTests` style:
  week boundaries, mid-week target change, streak build/break, empty weeks,
  future-day dots, per-activity sums and partial weeks.
- Migration coverage for the new `DayLedger.weeklyTargetAtThatTime` inline
  default.
- Existing tests of the four week-bucketing engines guard the `WeekMath`
  extraction.

## Phasing

- **Phase 1 (shippable as v1.9):** `weeklyGoldTarget` setting +
  `DayLedger` snapshot, `WeekMath` extraction, `GoalsMath` (consistency +
  streak), Today weekly-goal row + celebration, trophy badges, tests, FR/EN
  strings.
- **Phase 2:** per-activity distance goals — settings storage, hub ring +
  goal sheet, Today mini-ring rollup, `GoalsMath` distance outputs, tests.

## Out of scope

- Notifications / nudges of any kind.
- Adaptive or suggested targets derived from history.
- Session-count goals, monthly goals, pace goals.
- Historical snapshots for per-activity distance goals.
- Sharing (still deferred from v1.8).
