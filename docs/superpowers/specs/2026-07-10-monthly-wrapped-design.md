# Monthly Wrapped (v1.8) — Design

**Date:** 2026-07-10
**Status:** Approved by Farid (brainstorming session)
**Predecessors:** Trophy Room v1.7 (`2026-07-10-trophy-room-design.md`), Activity Hubs v1.6

## Summary

A Spotify-Wrapped-style monthly recap: when a month closes, a banner on the
Today screen invites the user into a full-screen, story-style card deck
recapping that month — totals with month-over-month comparison, highlights and
records, badges earned, consistency, and impact stats. Every past month with
data is browsable from History (full backfill via pure derivation). No
sharing/export in v1.8. No push notifications.

## Approved decisions

| Decision | Choice |
|---|---|
| Experience | Story-style full-screen card deck (tap/auto-advance) |
| Entry | Today banner when a month closes + browsable archive in History |
| Notifications | None (no push, no local) |
| Sharing | Out of scope for v1.8 |
| Content pillars | Totals+MoM (core), highlights & records, consistency & streaks, impact stats. No personality card. |
| Backfill | Full — any closed month with ≥1 workout gets a Wrapped |
| Container | Custom story container (segmented progress bar, tap zones, auto-advance), not TabView paging |
| Persistence | None new — pure derivation + UserDefaults seen-set |

## Architecture

### Math layer (pure, TDD)

New `Runner/Features/Wrapped/WrappedMath.swift`, following the
`HubMath`/`TrophyMath` house pattern: static pure functions over
`[ActivityWorkoutSummary]` (existing pure input model), calendar-injected,
no SwiftData model, no stored state.

- `WrappedMath.monthWrapped(_ summaries: [ActivityWorkoutSummary], month: WrappedMonth, calendar: Calendar) -> MonthWrapped?`
  — `nil` when the month has zero workouts. `MonthWrapped` carries an ordered
  `[WrappedCard]` (enum with associated values) so the view is a dumb renderer.
- `WrappedMath.availableMonths(_ summaries: [ActivityWorkoutSummary], asOf: Date, calendar: Calendar) -> [WrappedMonth]`
  — every **closed** month with ≥1 workout, newest first. Powers the archive
  and backfill; the in-progress month never appears.
- `WrappedMonth` is a `year`/`month` value type (Hashable, Comparable).
- Month-over-month delta: bucket the target month and the previous month
  directly. Previous month empty → absolutes only, no delta.
- **Badges earned in month M** (derived, not stored):
  `TrophyMath.allBadges(history ≤ end of M)` minus
  `TrophyMath.allBadges(history < start of M)`.
  **PRs set in month M**: same before/after diff via
  `ActivityStats.typeRecords`.
- Consistency within the month: active days, best streak clipped to month
  boundaries, per-day heat-strip values.
- Impact: sum calories and CO₂ across the month's workouts (missing values
  skipped).

### Card deck

Seven card types, in order; conditional cards drop out when empty:

1. **Intro** — "JUNE WRAPPED" month/year title card, sets the visual tone.
2. **Totals** — distance, workout count, active time; ▲/▼ % vs previous month.
3. **Highlights** — longest ride/run/walk of the month + PRs set in the month
   (with `CelebrationBurst` when PRs exist).
4. **Badges** *(conditional)* — Trophy Room badges unlocked during the month.
5. **Consistency** — active days, best streak, mini heat-strip calendar.
6. **Impact** — calories burned + CO₂ avoided, with a relatable equivalence
   line (e.g. "= 12 km by car").
7. **Finale** — one-screen recap of the month's headline numbers.

### Presentation & navigation

- **`WrappedStoryView`** presented via `fullScreenCover` (precedent:
  `RecordView`). Instagram-story container: segmented progress bar on top
  (one segment per card), tap-right advances, tap-left rewinds, ~6s
  auto-advance timer paused while touching, ✕ dismisses. Cards animate in
  when they become active. Deterministic content; animation is
  presentation-only.
- **Today banner** — when the latest closed month has a Wrapped and its
  `WrappedMonth` is not in the seen-set, `TodayView` shows a dismissible
  "Your June Wrapped is ready" banner. Tapping opens the deck and marks the
  month seen; the banner's own dismiss control also marks it seen.
- **`WrappedSeenStore`** — UserDefaults key `wrappedSeenMonths_v1`, mirroring
  `TrophySeenStore` (Features/Trophies/TrophySeenStore.swift).
- **Archive** — a "Monthly Wrapped" entry on `HistoryView` (alongside the
  Trophy Room card) pushes a month list (newest first from
  `availableMonths`); tapping a month opens the same full-screen deck. One
  deck view serves both entry points.
- No SwiftData schema changes, no HealthKit changes.

## Edge cases

- Only closed months exist; the current month gets no banner and no archive
  row.
- A month with zero workouts is absent from the archive — no empty-state deck.
- Previous month empty → totals card shows absolutes without a delta arrow.
- Workouts missing calories/CO₂ → sum what exists; the impact card drops out
  only if both monthly totals are zero.
- Badges card drops out when no badges were earned that month.
- Estimated distances count as-is (consistent with Hubs/Trophies).

## Localization

All user-facing strings in EN + FR via `Localizable.xcstrings`, using
`String(localized:)` as elsewhere.

## Testing

`RunnerTests/WrappedMathTests.swift` (Swift Testing, pure math — house
pattern):

- Month bucketing across month/year boundaries.
- Delta math incl. previous-month-empty.
- Badge-in-month and PR-in-month before/after diffing.
- Streak clipped to month edges; heat-strip day mapping.
- `availableMonths`: ordering, current-month exclusion, empty-month exclusion.
- Conditional card dropout (badges, impact).
- Existing suite (223 tests) stays green.

Views stay thin and untested, per house pattern.

## Delivery

- Version 1.8, single PR, squash-merge to main.
- Implementation drafted by Codex per the standing delegation workflow;
  iOS build/sim verification and git done inline.
