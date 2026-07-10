# Trophy Room (v1.7) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repo the standing delegation agreement applies: Codex drafts implementation; iOS build/test and git run inline in the main session.

**Goal:** Lifetime milestone badges per activity (Trophy Room screen), PR + new-badge celebration in the workout summary, and a next-milestone ticker on Today.

**Architecture:** A new pure `TrophyMath` layer derives all badge state (including earned dates) from `ActivityWorkoutSummary` history — no persisted badge records; the only persistence is a UserDefaults set of seen badge IDs (`TrophySeenStore`). Views stay thin and reuse the existing `@Query WorkoutRec` → summaries path.

**Tech Stack:** SwiftUI, SwiftData (read-only reuse), Swift Testing, xcodegen. Spec: `docs/superpowers/specs/2026-07-10-trophy-room-design.md`.

## Global Constraints

- Swift 6.0; follow existing house style (pure math + thin views).
- All new user-facing strings in EN + FR in `Runner/Resources/Localizable.xcstrings`.
- Auto-walk saves stay fully silent — no banner, no prompt (v1.5 philosophy).
- Do not modify `ActivityStats.milestones(_:)` math; only its HistoryView chips rendering is replaced.
- Test command: `xcodegen generate && xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test`
- Version bump at the end: `project.yml` → `CFBundleShortVersionString: "1.7"`, `CFBundleVersion: "9"`.

---

### Task 1: TrophyMath — Badge model, ladders, allBadges

**Files:**
- Create: `Runner/Features/Trophies/TrophyMath.swift`
- Test: `RunnerTests/TrophyMathTests.swift`

**Interfaces (Produces):**

```swift
enum BadgeKind: String, Sendable { case distance, count }
enum BadgeScope: Hashable, Sendable { case global, perType(ActivityType) }

struct Badge: Identifiable, Equatable, Sendable {
    let id: String        // "\(kind).\(scopeKey).\(Int(threshold))" e.g. "distance.bike.250", "count.global.100"; scopeKey: "global"|"run"|"walk"|"bike"
    let kind: BadgeKind
    let scope: BadgeScope
    let threshold: Double // km for .distance, workout count for .count
    let earned: Bool
    let progress: Double  // matches ActivityStats.milestones semantics: earned → 1, next unearned in its ladder → fraction, later → 0
    let earnedAt: Date?   // date of the workout that crossed the threshold
}

enum TrophyMath {
    static func allBadges(_ summaries: [ActivityWorkoutSummary]) -> [Badge]
}
```

**Ladders (exact):**
- distance global: 10, 25, 50, 100, 250, 500, 1000 km (same as existing `ActivityStats.milestones`)
- distance run: 10, 25, 50, 100, 250, 500, 1000 km
- distance walk: 10, 25, 50, 100, 250, 500, 1000 km
- distance bike: 25, 50, 100, 250, 500, 1000, 2500 km
- count global / run / walk / bike: 10, 25, 50, 100 workouts
→ 44 badges total, in stable order: global ladder first, then run, walk, bike; within scope distance then count, ascending threshold.

**Earned-date derivation:** sort summaries by start date ascending (input order must not matter), accumulate per-scope totals; the first workout whose inclusion reaches a threshold is that badge's `earnedAt`.

- [ ] **Step 1: Write failing tests** in `RunnerTests/TrophyMathTests.swift` (`import Testing`, `struct TrophyMathTests`, follow `ActivityStatsTests` fixture style for building `ActivityWorkoutSummary` values). Cases:
  - empty input → 44 badges, none earned, all `earnedAt == nil`
  - run summaries totaling 120 km → run ladder: 10/25/50/100 earned, 250 has `progress == 120.0/250.0`, 500 & 1000 have `progress == 0`
  - bike 30 km → `distance.bike.25` earned, `distance.bike.50` progress 0.6 (type-tuned ladder, not the run ladder)
  - earnedAt replay: run workouts Jan 1 (6 km), Jan 5 (5 km), Feb 1 (20 km) → `distance.run.10` earnedAt Jan 5, `distance.run.25` earnedAt Feb 1; shuffled input array gives identical results
  - 10 walk workouts → `count.walk.10` earned with `earnedAt` = 10th workout's date; `count.global.10` also earned
  - badge id format spot checks (`"distance.bike.250"`, `"count.global.100"`)
- [ ] **Step 2: Run tests, verify they fail** (compile error: TrophyMath not defined) via the Global Constraints test command filtered if practical.
- [ ] **Step 3: Implement `TrophyMath.allBadges`** (pure; single chronological pass accumulating global + per-type distance and count).
- [ ] **Step 4: Run tests, verify pass.**
- [ ] **Step 5: Commit** `feat: TrophyMath badge ladders with derived earned dates`

### Task 2: TrophyMath — achievements(history:candidate:)

**Files:**
- Modify: `Runner/Features/Trophies/TrophyMath.swift`
- Test: `RunnerTests/TrophyMathTests.swift`

**Interfaces (Produces):**

```swift
struct Achievement: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case newRecord(PersonalRecord)  // reuse existing PersonalRecord
        case newBadge(Badge)
    }
    let kind: Kind
    var id: String { /* record: "record.<type>.<recordKind>", badge: badge.id */ }
}

extension TrophyMath {
    static func achievements(history: [ActivityWorkoutSummary], candidate: ActivityWorkoutSummary) -> [Achievement]
}
```

**Semantics (exact):**
- New badges: badges earned in `allBadges(history + [candidate])` but not in `allBadges(history)`.
- New PRs: compare `ActivityStats.typeRecords(history, type: candidate.type)` vs `ActivityStats.typeRecords(history + [candidate], type: candidate.type)`; a record is a new PR when the candidate now holds it with a strictly better value. **Anti-spam rule:** if `history` contains no workout of `candidate.type`, suppress record achievements entirely (first-ever workout of a type is not "4 PRs"); badges still fire.
- Order: records first, then badges ascending threshold.

- [ ] **Step 1: Write failing tests:** candidate crosses 25 km run threshold AND is the longest run → both achievements, record first; candidate beats nothing → empty; first-ever bike ride of 12 km → no record achievements but `count.bike…`/distance badges as applicable; candidate crossing two thresholds in one workout (e.g. 9 km history + 20 km candidate crosses 10 and 25) → two badge achievements.
- [ ] **Step 2: Run tests, verify fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run tests, verify pass.**
- [ ] **Step 5: Commit** `feat: achievement detection for PRs and new badges`

### Task 3: TrophyMath — nextMilestone

**Files:**
- Modify: `Runner/Features/Trophies/TrophyMath.swift`
- Test: `RunnerTests/TrophyMathTests.swift`

**Interfaces (Produces):**

```swift
extension TrophyMath {
    static func nextMilestone(_ summaries: [ActivityWorkoutSummary]) -> Badge?
}
```

Unearned badge with highest `progress` across all ladders; tie → larger `threshold`. Returns nil when `summaries` is empty or there is no unearned badge.

- [ ] **Step 1: Failing tests:** bike 960 km + run 40 km → picks `distance.bike.1000` (progress 0.96); progress tie → larger threshold wins; no workouts → nil.
- [ ] **Step 2–4: fail → implement → pass.**
- [ ] **Step 5: Commit** `feat: next-milestone picker for Today ticker`

### Task 4: TrophySeenStore

**Files:**
- Create: `Runner/Features/Trophies/TrophySeenStore.swift`
- Test: `RunnerTests/TrophySeenStoreTests.swift`

**Interfaces (Produces):**

```swift
final class TrophySeenStore {
    init(defaults: UserDefaults = .standard)  // inject like SyncCoordinator
    func isSeen(_ id: String) -> Bool
    func markSeen(_ ids: [String])
}
// storage key: "trophySeenBadgeIDs_v1", value: [String]
```

- [ ] **Step 1: Failing tests** using `UserDefaults(suiteName:)` scratch suite (remove persistent domain in setup): unseen by default; markSeen persists across a second store instance; markSeen is additive/idempotent.
- [ ] **Step 2–4: fail → implement → pass.**
- [ ] **Step 5: Commit** `feat: TrophySeenStore for badge seen-state`

### Task 5: TrophyRoomView + HistoryView entry card

**Files:**
- Create: `Runner/Features/Trophies/TrophyRoomView.swift`
- Modify: `Runner/Features/History/HistoryView.swift` (replace `milestonesSection` chips with entry card)
- Modify: `Runner/Resources/Localizable.xcstrings`

**Interfaces (Consumes):** `TrophyMath.allBadges`, `TrophySeenStore`, existing summaries construction in HistoryView, `Theme`/design system.

**Behavior:**
- TrophyRoomView: sections Global / Run / Walk / Bike (localized headers). Badge grid (`LazyVGrid`, 3 columns): earned → colored (activity accent; Theme colors), emoji + threshold label + earned date (`Date.FormatStyle` short); locked → grayed with circular progress ring showing `progress`. Unseen earned badges show a small dot; `.onAppear` marks all currently earned badges seen via `TrophySeenStore`.
- HistoryView: entry card in place of the old milestone chips: trophy emoji, "Trophy Room" title, "N of 44 earned" subtitle, nearest `nextMilestone` line; `NavigationLink` pushing `TrophyRoomView`. Records section untouched.
- Strings EN+FR: "Trophy Room", "%d of %d earned", section headers ("Global", "Run", "Walk", "Bike" — reuse existing activity names if present), "Earned %@", ticker-style next line reuses Task 7 format if shared.

- [ ] **Step 1: Implement views** (no unit tests — views stay thin; math already covered).
- [ ] **Step 2: Build + full test suite green; open sim manually only if needed.**
- [ ] **Step 3: Commit** `feat: Trophy Room screen with badge grid and History entry card`

### Task 6: WorkoutSummaryView celebration banner

**Files:**
- Modify: `Runner/Features/Record/WorkoutSummaryView.swift` (add `var achievements: [Achievement] = []`)
- Modify: `Runner/Features/Record/RecordView.swift` (compute achievements when presenting the sheet)
- Modify: `Runner/Resources/Localizable.xcstrings`

**Interfaces (Consumes):** `TrophyMath.achievements(history:candidate:)`, `RecordRow.title/emoji` formatters for record naming, `Haptics.goalReached()`, `CelebrationBurst` pattern from `TodayView.swift:416` (extract or replicate a radial burst; do NOT couple TodayView internals — if extraction is clean, move `CelebrationBurst` to `Runner/DesignSystem/`).
- RecordView builds history summaries from its SwiftData context the same way HistoryView does, converts the finished `RecordedWorkout` to an `ActivityWorkoutSummary` candidate, and passes achievements into the sheet.
- Banner: top of sheet, celebratory background, burst animation + `Haptics.goalReached()` on appear, one row per achievement — records via RecordRow formatters ("🏆 Fastest 5K!"-style), badges "🎖️ 250 km lifetime run!" (localized EN+FR, km via existing distance formatting).
- Auto-walk path (silent save without summary sheet) is untouched.

- [ ] **Step 1: Implement banner + wiring.**
- [ ] **Step 2: Build + full suite green.**
- [ ] **Step 3: Commit** `feat: PR and badge celebration banner in workout summary`

### Task 7: Today ticker

**Files:**
- Modify: `Runner/Features/Today/TodayView.swift`
- Modify: `Runner/Resources/Localizable.xcstrings`

**Interfaces (Consumes):** `TrophyMath.nextMilestone` fed by TodayView's existing `@Query WorkoutRec` data.

**Behavior:** one-line row near the points/goal block: e.g. EN "38 km to 1,000 km lifetime cycling" / count form "3 rides to 50 lifetime rides"; FR equivalents. Hidden when `nextMilestone` is nil. Display-only (no navigation). Remaining = `threshold - current` derived from badge progress; format distances with the app's existing km formatting.

- [ ] **Step 1: Implement row + strings.**
- [ ] **Step 2: Build + full suite green.**
- [ ] **Step 3: Commit** `feat: next-milestone ticker on Today`

### Task 8: Version bump, full verification, PR

**Files:**
- Modify: `project.yml` (`CFBundleShortVersionString: "1.7"`, `CFBundleVersion: "9"`)

- [ ] **Step 1: Bump version, `xcodegen generate`.**
- [ ] **Step 2: Full suite:** run the Global Constraints test command → all tests pass (expect ~220+, was ~205).
- [ ] **Step 3: Commit** `chore: bump version to 1.7 (9)`
- [ ] **Step 4: Push branch `v1.7-trophy-room`, open PR** "Runner v1.7 — Trophy Room" with summary of the three features; squash-merge policy per house rules.
