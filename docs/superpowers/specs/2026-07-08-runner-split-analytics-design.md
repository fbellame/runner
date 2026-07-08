# Runner v1.2 — Phase 3a: Per-run Split Analytics

**Date:** 2026-07-08
**Branch:** `runner-v1`
**Epic:** v1.2 History & Trends (Phase 3a of 4)

## Goal

Deepen `WorkoutDetailView` so a single run's per-km splits tell a story: which km
was fastest, which was slowest, whether the run was a negative split, and how each
km compares to the run's average — shown as a pace bar chart on top of the existing
exact-times list.

No new sensors, no recording changes, no SwiftData migration. Everything derives
from the existing `WorkoutRec.splitSeconds: [Double]` (per-**completed**-km
durations in seconds). Because each entry covers exactly one kilometre, a split's
seconds value *is* its seconds-per-km pace — no partial-km handling needed.

## Architecture

Follows the established Phase 1/2 pattern: a pure, Foundation-only aggregation
module returning structured facts (not sentences), consumed by a SwiftUI view that
reuses existing DesignSystem components.

### Pure module — `Runner/Features/History/SplitStats.swift`

Foundation only. No SwiftUI, no SwiftData. Mirrors `InsightsMath` / `ActivityStats`.

```swift
struct SplitDetail: Identifiable {
    let km: Int              // 1-based
    let seconds: Double      // == seconds-per-km pace for this km
    let deltaFromAverage: Double  // seconds vs run average (+ slower, - faster)
    let isFastest: Bool
    let isSlowest: Bool
    var id: Int { km }
}

enum NegativeSplit: Equatable {
    case negative(deltaSeconds: Double)  // 2nd half faster; delta = firstHalfAvg - secondHalfAvg (> 0)
    case positive(deltaSeconds: Double)  // 2nd half slower;  delta = secondHalfAvg - firstHalfAvg (> 0)
    case even                            // within tolerance band
    case notApplicable                   // < 2 valid splits
}

struct SplitAnalysis {
    let splits: [SplitDetail]
    let fastestKmIndex: Int?             // index into splits (0-based); nil when empty
    let slowestKmIndex: Int?
    let averageSecPerKm: Double?         // nil when empty
    let negativeSplit: NegativeSplit
}

enum SplitStats {
    static func analyze(_ splitSeconds: [Double]) -> SplitAnalysis
}
```

**Rules:**
- Input is filtered to valid splits (`seconds > 0`); zero/negative entries dropped
  so a corrupt import can't skew the average or min/max.
- `averageSecPerKm` = sum(valid seconds) / count. `nil` when no valid splits.
- `fastestKmIndex` = index of min seconds; `slowestKmIndex` = index of max. Ties
  resolve to the earliest km. `nil` when empty. When exactly one split,
  fastest == slowest == that km.
- `deltaFromAverage` = `seconds - average` per km.
- **Negative-split detection**: split the valid km sequence into first half and
  second half by count. Odd count → drop the single middle km (standard racing
  convention). `firstHalfAvg` = mean of the first `floor(n/2)` km, `secondHalfAvg`
  = mean of the last `floor(n/2)` km. Let `delta = firstHalfAvg - secondHalfAvg`.
  - `delta > band` → `.negative(deltaSeconds: delta)` (finished faster — good)
  - `delta < -band` → `.positive(deltaSeconds: -delta)`
  - otherwise → `.even`
  - `< 2` valid splits → `.notApplicable`
  - `band = negativeSplitBandSecPerKm = 2.0` (private constant).

### View — `WorkoutDetailView`

Replace the current bare `SplitsCard(splitSeconds:title:)` call (only rendered when
`!workout.splitSeconds.isEmpty`) with a new `SplitAnalysisCard` composed of three
stacked parts inside the History feature (component may live in
`WorkoutDetailView.swift` or `DesignSystem/Components.swift` — keep it near its use):

1. **Highlights row** — compact tiles / labels:
   - Fastest: `Km N · m:ss`
   - Slowest: `Km N · m:ss`
   - Negative-split verdict: `✓ Negative split` (accent/`rLime`), `Positive split`
     (`rOrange`), `Even pace` (`rTextSecondary`). Hidden when `.notApplicable`.
2. **Pace bar chart** — Swift `Chart` of `SplitDetail`:
   - One `BarMark` per km, `x = km` (or vertical bars), `y = seconds`.
   - Fastest km bar in `workout.type.accent`; slowest in `rOrange`; the rest muted
     (e.g. `rTextSecondary` / accent at reduced opacity).
   - `RuleMark(y: averageSecPerKm)` dashed, labelled "Avg", so each bar reads as
     above/below the run's average pace.
   - Y axis labelled so "lower = faster" is clear (reuse pattern from Insights
     pace chart caption).
   - Rendered only when `splits.count >= 2`; for a single split just show the list.
3. **Exact-times list** — the existing per-km rows (reuse `SplitsCard` internals or
   inline), with the fastest km starred (★). This keeps precise numbers per the
   approved "Chart + list (keep both)" layout.

The three stat tiles (Points/Distance/Time) and the route map above are unchanged.

## i18n

New English keys with French translations in `Runner/Resources/Localizable.xcstrings`:

| English | French |
|---|---|
| Fastest km | Km le plus rapide |
| Slowest km | Km le plus lent |
| Negative split | Négatif split |
| Positive split | Positif split |
| Even pace | Allure régulière |
| Pace per km (lower = faster) | Allure par km (plus bas = plus rapide) |
| Avg | Moy |
| Second half %@ faster | 2ᵉ moitié %@ plus rapide |
| Second half %@ slower | 2ᵉ moitié %@ plus lente |

(Final French wording refined during implementation for naturalness; assemble
sentences from localized fragments — never English-concatenate.)

## Testing — `RunnerTests/SplitStatsTests.swift`

Swift Testing (`import Testing`, `@Test`, `#expect`), matching
`InsightsMathTests` / `ActivityStatsTests`. Cases:

1. Empty input → empty splits, nil indices, nil average, `.notApplicable`, no crash.
2. Single split → one detail, fastest == slowest, average == that value,
   `.notApplicable`.
3. Multi-km: correct average, fastest/slowest indices, per-km `deltaFromAverage`.
4. Tie on fastest resolves to earliest km.
5. Invalid entries (`0`, negative) filtered out of average and min/max.
6. Negative split: descending second half → `.negative` with correct delta.
7. Positive split: ascending → `.positive` with correct delta.
8. Even within band (diff ≤ 2 s) → `.even`.
9. Odd km count drops the middle km in the half comparison (verify with a value
   whose inclusion would flip the verdict).
10. Exactly two splits: first vs second half = km1 vs km2.

## Success criteria

- `SplitStats.analyze` is pure and fully unit-tested (≥ 9 substantive cases).
- `WorkoutDetailView` shows highlights + pace bar chart (with average rule) + exact
  list, for a workout that has splits; degrades cleanly for 0/1 split.
- French present for all new strings.
- `xcodegen generate` clean; `xcodebuild … build test` green on an iPhone sim.

## Out of scope

- Editing/recomputing splits (recording is unchanged).
- Splits for imported (external) workouts that have none — they simply show no
  split card, as today.
- Elevation/HR splits (no such data captured).
