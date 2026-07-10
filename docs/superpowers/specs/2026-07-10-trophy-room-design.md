# Trophy Room (v1.7) — Design

**Date:** 2026-07-10
**Status:** Approved by Farid (brainstorming session)
**Epic:** Trophy Room — lifetime milestone badges per activity, PR celebration at
workout-save time, Today next-milestone ticker. Follows v1.6 Activity Hubs;
precedes v1.8 Monthly Wrapped.

## Goals

1. Turn the existing global milestone chips into a real badge collection with
   per-activity ladders and a dedicated full-screen Trophy Room.
2. Surface new personal records and newly earned badges the moment a workout
   is finished, instead of leaving them to be discovered later in a list.
3. Give the Today screen a "next milestone" ticker that always shows the most
   within-reach lifetime goal.

## Decisions made (do not re-litigate)

- **Placement:** Trophy Room is a full screen pushed from a HistoryView entry
  card. The card replaces the current Milestones chips section. No new tab, no
  Today deep link.
- **Ladders:** per-activity distance ladders are type-tuned (run/walk
  10/25/50/100/250/500/1000 km; bike 25/50/100/250/500/1000/2500 km) plus a
  10/25/50/100 workout-count ladder per type. The global ladder is unchanged
  (10/25/50/100/250/500/1000 km + 10/25/50/100 workouts).
- **Celebration:** hero banner at the top of WorkoutSummaryView covering both
  new PRs and newly crossed badges, with CelebrationBurst-style animation and
  success haptic; multiple achievements stack as rows.
- **Ticker:** across all open ladders, show the next milestone with the
  highest progress fraction; ties broken by larger threshold. Display-only.
- **Persistence:** pure derivation. Badges and earned dates are computed from
  `WorkoutRec` history on the fly; the only persisted state is a set of "seen"
  badge IDs in UserDefaults.
- **Auto-walks stay fully silent** (v1.5 philosophy): no banner or prompt;
  badges earned by an auto-walk simply appear as unseen in the Trophy Room.

## Architecture

### 1. Math layer — `TrophyMath` (pure, TDD-first)

New file `Runner/Features/Trophies/TrophyMath.swift`. Pure functions over
`ActivityWorkoutSummary` arrays, alongside (not replacing) `ActivityStats`.
`ActivityStats.milestones(_:)` remains for the global ladder math but its
HistoryView chips rendering is removed.

**Model**

```swift
struct Badge {
    let id: String            // stable, e.g. "distance.bike.250", "count.global.100"
    let kind: BadgeKind       // .distance | .count
    let scope: BadgeScope     // .global | .perType(ActivityType)
    let threshold: Double     // km for .distance, count for .count
    let earned: Bool
    let progress: Double      // 0...1; next unearned badge gets fractional progress
    let earnedAt: Date?       // date of the workout that crossed the threshold
}
```

Badge IDs are stable strings (`kind.scope.threshold`) so the seen-set survives
recomputation, reinstalls, and re-imports.

**Functions**

- `allBadges(_ summaries:) -> [Badge]` — full ladder set (global + per type),
  earned/progress state, and `earnedAt` derived by replaying summaries in
  chronological order and recording which workout crossed each threshold.
- `achievements(history:candidate:) -> [Achievement]` — given existing
  summaries and one just-finished workout, returns:
  - new PRs: `ActivityStats.typeRecords` computed with and without the
    candidate; any record the candidate now holds is a new PR;
  - new badges: badges whose threshold is crossed only when the candidate is
    included.
  `Achievement` is an enum-like value with an emoji/title/detail suitable for
  a banner row (localized at the view layer).
- `nextMilestone(_ summaries:) -> Badge?` — the unearned badge with the
  highest progress across all ladders; tie → larger threshold; nil when every
  ladder is complete or there are no workouts.

### 2. Seen-state — `TrophySeenStore`

UserDefaults-backed set of badge ID strings (defaults injected, following the
`SyncCoordinator` pattern). API: `isSeen(_ id:)`, `markSeen(_ ids:)`.
No other persistence is added — no SwiftData schema change, no backfill, no
upgrade re-import.

### 3. UI

- **`TrophyRoomView`** (new, `Runner/Features/Trophies/`): full screen pushed
  from HistoryView. Sections: Global, Run, Walk, Bike. Badge grid; earned
  badges rendered in color with earned date, locked badges grayed with a
  progress ring. Unseen earned badges show a dot; on appear the view marks all
  visible earned badges seen.
- **`HistoryView`**: the milestones chips section is replaced by a Trophy Room
  entry card showing earned-badge count and the nearest next badge; tapping
  pushes `TrophyRoomView`. The Records section is untouched.
- **`WorkoutSummaryView`**: new parameter `achievements: [Achievement] = []`.
  When non-empty, a hero celebration banner tops the sheet: CelebrationBurst-
  style radial animation + `Haptics.goalReached()`, one row per achievement
  (e.g. "🏆 Fastest 5K!", "🎖️ 250 km lifetime run!"). `RecordView` computes
  `TrophyMath.achievements(history:candidate:)` from saved `WorkoutRec`
  summaries when presenting the sheet.
- **`TodayView`**: one-line ticker row near the points/goal block, e.g.
  "38 km to 1,000 km lifetime cycling", driven by
  `TrophyMath.nextMilestone`. Display-only; hidden when `nextMilestone` is
  nil.

### 4. Data flow

Views already build `ActivityWorkoutSummary` arrays from SwiftData `@Query`
`WorkoutRec` rows (HistoryView pattern); Trophy Room, ticker, and achievement
detection reuse that path. No new stores, coordinators, or view models.

## Edge cases

- **Discarded workout:** achievements are shown in the pre-save sheet; if the
  user discards, nothing was saved, so no badge or PR materializes — same
  contingency as the stats already displayed in the sheet.
- **Multiple crossings in one workout:** all achievements stack as banner rows.
- **HealthKit re-import / merged history:** derivation recomputes from
  whatever is in the store; stable badge IDs keep the seen-set valid.
- **Empty history:** Trophy Room shows all-locked ladders; ticker hidden.

## Localization

All new user-facing strings in EN + FR in `Localizable.xcstrings` (badge
titles, banner strings, ticker format, Trophy Room section headers, entry
card).

## Testing

`RunnerTests/TrophyMathTests.swift` (Swift Testing, house TDD pattern):

- ladder contents and type-tuned thresholds per scope;
- earned-date replay (correct crossing workout, out-of-order input);
- `achievements`: new PR only, new badge only, both, none, multiple badges in
  one workout;
- `nextMilestone`: highest-progress pick, threshold tie-break, complete
  ladders → nil, empty input → nil.

Views stay thin; no UI tests. Suite grows from ~205 green tests.

## Delivery

One PR — "Runner v1.7 — Trophy Room" — squash-merged to main; version bump to
1.7. Implementation drafted by Codex per the delegation agreement; iOS
build/sim verification and git run inline.
