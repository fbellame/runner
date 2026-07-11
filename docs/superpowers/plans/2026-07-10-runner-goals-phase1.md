# Runner v1.9 Goals — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Weekly consistency goal — "hit your daily points goal N days this week" (N = 1–7, default 3) — with a Today weekly-goal row (seven day-dots + streak), completion celebration, historical-honesty snapshot on `DayLedger`, weekly trophy badges, and a `WeekMath` extraction of the duplicated Monday-week helper.

**Architecture:** A pure derivation engine `GoalsMath` (the `WrappedMath` pattern: static funcs, injected `Calendar`, no side effects) computes current-week status, completed weeks, and the weekly streak from `DayLedger` projections. The target the user sets lives on `AppModel` (UserDefaults), and each ledgered day snapshots the target in effect (`DayLedger.weeklyTargetAtThatTime`) so raising the target never rewrites history — the exact mechanism `goalAtThatTime` already uses.

**Tech Stack:** SwiftUI, SwiftData, Swift Testing (`@Test`/`#expect`), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-07-10-runner-goals-design.md` (Phase 1 scope only — NO per-activity distance goals, that is Phase 2).

## Global Constraints

- **Silent, in-app only.** No notifications, no permission prompts, no banners.
- `weeklyGoldTarget` range **1...7**, default **3**.
- Week starts **Monday**, via the `(weekday + 5) % 7` idiom (being extracted to `WeekMath`).
- A past week is judged by the `weeklyTargetAtThatTime` snapshot of its **latest ledgered day**; the current week is judged by the **live** target.
- A week with zero ledgered days breaks the weekly streak.
- All user-facing strings via `String(localized:)` with **en + fr** entries in `Runner/Resources/Localizable.xcstrings` (en is the source language — the key itself is the English copy; only `fr` needs an entry).
- Pure engines take `Calendar` as a parameter — never `Calendar.current` inside engine code. Views pass `.current`.
- Tests pin `Calendar(identifier: .gregorian)` + `TimeZone(identifier: "America/Toronto")!`.
- New `.swift` files are auto-globbed by XcodeGen, but you MUST run `xcodegen generate` after adding files, before building.
- Test command (simulator name is `RunnerSim`):
  ```bash
  xcodegen generate && xcodebuild -project Runner.xcodeproj -scheme Runner \
    -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -20
  ```
  For a single suite append `-only-testing:RunnerTests/<SuiteName>` before `test`… i.e. `xcodebuild -project … -destination … test -only-testing:RunnerTests/GoalsMathTests`.
- Reference date facts for tests: **2026-07-06 is a Monday**; 2026-07-10 is a Friday.
- Commit after every task; end commit messages with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Extract `WeekMath.mondayStart` (shared week helper)

**Files:**
- Create: `Runner/Features/Shared/WeekMath.swift`
- Modify: `Runner/Features/Today/WeeklyRecapMath.swift:90-95` (delete private helper)
- Modify: `Runner/Features/History/HubMath.swift:209-214` (delete private helper)
- Modify: `Runner/Features/History/ActivityStats.swift:249-254` (delete private helper)
- Modify: `Runner/Features/History/InsightsMath.swift:237-242` (delete private helper)
- Test: `RunnerTests/WeekMathTests.swift` (new)

**Interfaces:**
- Produces: `WeekMath.mondayStart(for: Date, calendar: Calendar) -> Date` — used by all later tasks (`GoalsMath` in Task 4).

All four `*Math` files contain this byte-identical `private static func`:

```swift
    private static func mondayStart(for date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: day)!
    }
```

- [ ] **Step 1: Write the failing test**

Create `RunnerTests/WeekMathTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

struct WeekMathTests {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(timeZone: cal.timeZone,
                                      year: year, month: month, day: day, hour: hour))!
    }

    @Test func midWeekMapsBackToMonday() {
        // 2026-07-10 is a Friday; its week starts Monday 2026-07-06.
        #expect(WeekMath.mondayStart(for: date(2026, 7, 10), calendar: cal)
                == cal.startOfDay(for: date(2026, 7, 6)))
    }

    @Test func mondayAndSundayBoundaries() {
        // A Monday maps to itself (start of day).
        #expect(WeekMath.mondayStart(for: date(2026, 7, 6, hour: 0), calendar: cal)
                == cal.startOfDay(for: date(2026, 7, 6)))
        // Sunday 2026-07-12 still belongs to the week of Monday 2026-07-06.
        #expect(WeekMath.mondayStart(for: date(2026, 7, 12, hour: 23), calendar: cal)
                == cal.startOfDay(for: date(2026, 7, 6)))
    }

    @Test func dstTransitionWeek() {
        // DST starts 2026-03-08 (Sunday) in Toronto; Thu 2026-03-12 maps to Mon 2026-03-09.
        #expect(WeekMath.mondayStart(for: date(2026, 3, 12), calendar: cal)
                == cal.startOfDay(for: date(2026, 3, 9)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test -only-testing:RunnerTests/WeekMathTests 2>&1 | tail -20`
Expected: BUILD FAILURE — `cannot find 'WeekMath' in scope`.

- [ ] **Step 3: Create `Runner/Features/Shared/WeekMath.swift`**

```swift
import Foundation

/// Monday-based week bucketing shared by the weekly engines
/// (WeeklyRecapMath, HubMath, ActivityStats, InsightsMath, GoalsMath).
enum WeekMath {
    /// Start of day of the Monday beginning the week that contains `date`.
    static func mondayStart(for date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: day)!
    }
}
```

- [ ] **Step 4: Point the four engines at it**

In each of the four files, delete the `private static func mondayStart(for:calendar:)` helper and replace every call `mondayStart(for: X, calendar: Y)` with `WeekMath.mondayStart(for: X, calendar: Y)`. Call sites:
- `WeeklyRecapMath.swift:32`
- `HubMath.swift:136`, `HubMath.swift:154`
- `ActivityStats.swift:109`
- `InsightsMath.swift:71`, `InsightsMath.swift:85`, `InsightsMath.swift:195`

Verify no stragglers: `rg -n "daysSinceMonday" Runner/` must only match `WeekMath.swift`.

- [ ] **Step 5: Run the guarding suites and make sure they pass**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test -only-testing:RunnerTests/WeekMathTests -only-testing:RunnerTests/WeeklyRecapMathTests -only-testing:RunnerTests/HubMathTests -only-testing:RunnerTests/ActivityStatsTests -only-testing:RunnerTests/InsightsMathTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Runner/Features/Shared/WeekMath.swift Runner/Features/Today/WeeklyRecapMath.swift Runner/Features/History/HubMath.swift Runner/Features/History/ActivityStats.swift Runner/Features/History/InsightsMath.swift RunnerTests/WeekMathTests.swift
git commit -m "refactor: extract shared WeekMath.mondayStart from four weekly engines"
```

---

### Task 2: `weeklyGoldTarget` setting on AppModel + Settings stepper

**Files:**
- Modify: `Runner/App/AppModel.swift` (near `dailyGoal`, lines ~13-54, and `init` ~line 61)
- Modify: `Runner/Features/Settings/SettingsView.swift:21-31` (inside the "Daily goal" Section)
- Modify: `Runner/Resources/Localizable.xcstrings`
- Test: `RunnerTests/AppModelTests.swift` (add tests)

**Interfaces:**
- Produces: `AppModel.weeklyGoldTarget: Int`, `AppModel.weeklyTargetKey: String`, `AppModel.weeklyTargetRange = 1...7`, `AppModel.storedWeeklyTarget() -> Int` — consumed by Tasks 3 and 7.

- [ ] **Step 1: Write the failing test**

Add to `RunnerTests/AppModelTests.swift` (match the file's existing suite struct and fixture style; if existing tests isolate UserDefaults, do the same):

```swift
    @Test func storedWeeklyTargetDefaultsAndClamps() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AppModel.weeklyTargetKey)
        #expect(AppModel.storedWeeklyTarget() == 3)

        defaults.set(99, forKey: AppModel.weeklyTargetKey)
        #expect(AppModel.storedWeeklyTarget() == 7)

        defaults.set(0, forKey: AppModel.weeklyTargetKey)
        #expect(AppModel.storedWeeklyTarget() == 1)

        defaults.set(5, forKey: AppModel.weeklyTargetKey)
        #expect(AppModel.storedWeeklyTarget() == 5)
        defaults.removeObject(forKey: AppModel.weeklyTargetKey)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test -only-testing:RunnerTests/AppModelTests 2>&1 | tail -20`
Expected: BUILD FAILURE — `type 'AppModel' has no member 'weeklyTargetKey'`.

- [ ] **Step 3: Implement on AppModel**

In `Runner/App/AppModel.swift`, next to the existing `goalKey`/`goalRange`/`dailyGoal`/`storedGoal()` block, add (mirroring it exactly):

```swift
    static let weeklyTargetKey = "weeklyGoldTarget"
    /// Allowed weekly consistency target — gold days per week.
    static let weeklyTargetRange = 1...7

    var weeklyGoldTarget: Int {
        didSet {
            let clamped = min(max(weeklyGoldTarget, Self.weeklyTargetRange.lowerBound), Self.weeklyTargetRange.upperBound)
            if clamped != weeklyGoldTarget {
                weeklyGoldTarget = clamped
                return
            }
            UserDefaults.standard.set(weeklyGoldTarget, forKey: Self.weeklyTargetKey)
            Task { await sync.syncNow() }
        }
    }

    static func storedWeeklyTarget() -> Int {
        let raw = UserDefaults.standard.object(forKey: weeklyTargetKey) as? Int ?? 3
        return min(max(raw, weeklyTargetRange.lowerBound), weeklyTargetRange.upperBound)
    }
```

In `init`, directly after `self.dailyGoal = Self.storedGoal()`, add:

```swift
        self.weeklyGoldTarget = Self.storedWeeklyTarget()
```

- [ ] **Step 4: Run test to verify it passes**

Run: same command as Step 2.
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Add the Settings stepper**

In `Runner/Features/Settings/SettingsView.swift`, inside the existing `Section(String(localized: "Daily goal"))`, directly below the daily-goal `Stepper`, add:

```swift
                    Stepper(value: $model.weeklyGoldTarget, in: AppModel.weeklyTargetRange) {
                        HStack {
                            Text(String(localized: "Gold days per week"))
                            Spacer()
                            Text("\(model.weeklyGoldTarget)")
                                .foregroundStyle(Color.rLime)
                                .bold()
                        }
                    }
```

- [ ] **Step 6: Add the localization entry**

In `Runner/Resources/Localizable.xcstrings`, add (keys are sorted alphabetically — insert in order):

```json
    "Gold days per week": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Jours en or par semaine"
          }
        }
      }
    },
```

- [ ] **Step 7: Build to verify**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add Runner/App/AppModel.swift Runner/Features/Settings/SettingsView.swift Runner/Resources/Localizable.xcstrings RunnerTests/AppModelTests.swift
git commit -m "feat: weeklyGoldTarget setting (1-7 gold days/week, default 3) with Settings stepper"
```

---

### Task 3: `DayLedger.weeklyTargetAtThatTime` snapshot plumbing

**Files:**
- Modify: `Runner/Core/Store/Models.swift:4-49` (`DayLedger`)
- Modify: `Runner/Core/PointsEngine/LedgerBuilder.swift` (`LedgerDay` + `build`)
- Modify: `Runner/Core/Store/DataStore.swift` (`upsert` insert path ~line 56; new `weeklyTargetProvider` next to `goalProvider` ~line 183)
- Modify: `Runner/Core/Store/SyncCoordinator.swift` (init ~line 24; build call ~line 194)
- Modify: `Runner/App/AppModel.swift:64` (SyncCoordinator construction)
- Test: `RunnerTests/LedgerBuilderTests.swift`, `RunnerTests/DataStoreTests.swift` (add tests; fix existing call sites)

**Interfaces:**
- Consumes: `AppModel.storedWeeklyTarget()` (Task 2).
- Produces: `DayLedger.weeklyTargetAtThatTime: Int` (default 3), `LedgerDay.weeklyTarget: Int`, `LedgerBuilder.build(days:goalProvider:weeklyTargetProvider:initialStreak:)`, `DataStore.weeklyTargetProvider(currentTarget:from:) -> (Date) -> Int`. Task 4's `GoalLedgerDay` projection reads `weeklyTargetAtThatTime`.

- [ ] **Step 1: Write the failing tests**

Add to `RunnerTests/LedgerBuilderTests.swift` (reuse the file's existing `DayActivity` fixture style — look at the top of the file):

```swift
    @Test func snapshotsWeeklyTargetPerDay() {
        let days = [DayActivity(date: .now, steps: 0, workouts: [])]
        let out = LedgerBuilder.build(days: days,
                                      goalProvider: { _ in 100 },
                                      weeklyTargetProvider: { _ in 4 },
                                      initialStreak: 0)
        #expect(out.count == 1)
        #expect(out[0].weeklyTarget == 4)
    }
```

In `RunnerTests/DataStoreTests.swift`, the `ledgerDay` fixture (lines 9-17) constructs `LedgerDay` and must gain the new field — add a defaulted param and pass it through:

```swift
    private func ledgerDay(_ offset: Int, total: Int, goal: Int = 100,
                           weeklyTarget: Int = 3) -> LedgerDay {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: .now))!
        return LedgerDay(date: date, steps: total * 100,
                         breakdown: PointsBreakdown(stepPoints: total, workoutPoints: 0,
                                                    multiplier: 1.0, total: total),
                         goal: goal, weeklyTarget: weeklyTarget,
                         isGold: total >= goal, streakAfter: total >= goal ? 1 : 0)
    }
```

Then add, next to the existing `goalProviderUsesStoredGoalForPastDaysOnly` (line 37):

```swift
    @Test func weeklyTargetProviderUsesStoredTargetForPastDaysOnly() throws {
        let store = try makeStore()
        try store.upsert([ledgerDay(-1, total: 80, weeklyTarget: 2),
                          ledgerDay(0, total: 90, weeklyTarget: 2)])
        let provider = store.weeklyTargetProvider(currentTarget: 5)
        let cal = Calendar.current
        // Past day: frozen snapshot.
        #expect(provider(cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: .now))!) == 2)
        // Today has a stored ledger, but a target edit must apply to today forward:
        #expect(provider(cal.startOfDay(for: .now)) == 5)
        // Unledgered past day falls back to the current target.
        #expect(provider(cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: .now))!) == 5)
    }
```

Also add:

```swift
    @Test func dayLedgerDefaultsWeeklyTargetTo3() {
        // Guards the inline default that makes the SwiftData column lightweight-migratable.
        let row = DayLedger(date: .now, steps: 0, stepPoints: 0, workoutPoints: 0,
                            multiplier: 1, totalPoints: 0, goalAtThatTime: 100,
                            isGold: false, streakAfter: 0)
        #expect(row.weeklyTargetAtThatTime == 3)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test -only-testing:RunnerTests/LedgerBuilderTests -only-testing:RunnerTests/DataStoreTests 2>&1 | tail -20`
Expected: BUILD FAILURE — extra argument / missing member errors.

- [ ] **Step 3: Add the model field (migration-safe)**

In `Runner/Core/Store/Models.swift`, inside `DayLedger` after `var activeSeconds: Double = 0`:

```swift
    // v1.9: weekly consistency target (gold days/week) in effect that day.
    // Inline default backfills the column on lightweight migration of pre-v1.9
    // stores, mirroring activeCalories/distanceMeters/activeSeconds.
    var weeklyTargetAtThatTime: Int = 3
```

Extend `DayLedger.init` with a trailing defaulted parameter and assignment:

```swift
    init(date: Date, steps: Int, stepPoints: Int, workoutPoints: Int, multiplier: Double,
         totalPoints: Int, goalAtThatTime: Int, isGold: Bool, streakAfter: Int,
         activeCalories: Double = 0, distanceMeters: Double = 0, activeSeconds: Double = 0,
         weeklyTargetAtThatTime: Int = 3) {
        ...existing assignments...
        self.weeklyTargetAtThatTime = weeklyTargetAtThatTime
    }
```

In `DayLedger.apply(_ day: LedgerDay)`, after `goalAtThatTime = day.goal`, add:

```swift
        weeklyTargetAtThatTime = day.weeklyTarget
```

- [ ] **Step 4: Thread it through LedgerBuilder**

In `Runner/Core/PointsEngine/LedgerBuilder.swift`:

```swift
struct LedgerDay: Equatable, Sendable {
    let date: Date
    let steps: Int
    let breakdown: PointsBreakdown
    let goal: Int
    let weeklyTarget: Int
    let isGold: Bool
    let streakAfter: Int
}

enum LedgerBuilder {
    static func build(days: [DayActivity],
                      goalProvider: (Date) -> Int,
                      weeklyTargetProvider: (Date) -> Int,
                      initialStreak: Int) -> [LedgerDay] {
        var streak = initialStreak
        var out: [LedgerDay] = []
        out.reserveCapacity(days.count)
        for day in days {
            let goal = goalProvider(day.date)
            let breakdown = PointsEngine.breakdown(steps: day.steps,
                                                   workouts: day.workouts,
                                                   streakBefore: streak)
            let isGold = breakdown.total >= goal
            streak = isGold ? streak + 1 : 0
            out.append(LedgerDay(date: day.date, steps: day.steps, breakdown: breakdown,
                                 goal: goal, weeklyTarget: weeklyTargetProvider(day.date),
                                 isGold: isGold, streakAfter: streak))
        }
        return out
    }
}
```

Fix every other `LedgerBuilder.build(` and `LedgerDay(` construction site — find them with `rg -n "LedgerBuilder.build\(|LedgerDay\(" Runner RunnerTests`. In tests, pass `weeklyTargetProvider: { _ in 3 }` / `weeklyTarget: 3` unless the test is specifically about the weekly target.

- [ ] **Step 5: DataStore — write on insert + provider**

In `Runner/Core/Store/DataStore.swift` `upsert`, extend the insert path's `DayLedger(...)` call with `weeklyTargetAtThatTime: day.weeklyTarget`:

```swift
                let inserted = DayLedger(date: key,
                                         steps: day.steps,
                                         stepPoints: day.breakdown.stepPoints,
                                         workoutPoints: day.breakdown.workoutPoints,
                                         multiplier: day.breakdown.multiplier,
                                         totalPoints: day.breakdown.total,
                                         goalAtThatTime: day.goal,
                                         isGold: day.isGold,
                                         streakAfter: day.streakAfter,
                                         weeklyTargetAtThatTime: day.weeklyTarget)
```

Directly below the existing `goalProvider(currentGoal:from:)` (~line 183), add its mirror:

```swift
    func weeklyTargetProvider(currentTarget: Int, from: Date? = nil) -> (Date) -> Int {
        // Mirrors goalProvider: past days return their frozen snapshot,
        // today and forward return the live target.
        let rows: [DayLedger]
        if let from {
            rows = (try? ledgers(from: from, through: .now)) ?? []
        } else {
            rows = (try? context.fetch(FetchDescriptor<DayLedger>())) ?? []
        }
        let stored = Dictionary(uniqueKeysWithValues: rows.map { ($0.date, $0.weeklyTargetAtThatTime) })
        let todayStart = Calendar.current.startOfDay(for: .now)
        return { date in
            let day = Calendar.current.startOfDay(for: date)
            guard day < todayStart else { return currentTarget }
            return stored[day] ?? currentTarget
        }
    }
```

- [ ] **Step 6: SyncCoordinator + AppModel wiring**

In `Runner/Core/Store/SyncCoordinator.swift`, add a stored closure and init parameter (after `currentGoal`):

```swift
    private let currentWeeklyTarget: () -> Int

    init(health: HealthStoring, store: DataStore, currentGoal: @escaping () -> Int,
         currentWeeklyTarget: @escaping () -> Int,
         metricsProvider: @escaping () -> BodyMetrics, defaults: UserDefaults = .standard) {
        ...
        self.currentWeeklyTarget = currentWeeklyTarget
        ...
    }
```

At the `LedgerBuilder.build` call (~line 194):

```swift
            let ledgers = LedgerBuilder.build(days: days,
                                              goalProvider: store.goalProvider(currentGoal: currentGoal(),
                                                                               from: windowStart),
                                              weeklyTargetProvider: store.weeklyTargetProvider(currentTarget: currentWeeklyTarget(),
                                                                                               from: windowStart),
                                              initialStreak: initialStreak)
```

Update the two construction sites (`rg -n "SyncCoordinator\(" Runner RunnerTests`):
- `Runner/App/AppModel.swift:64` — add `currentWeeklyTarget: { Self.storedWeeklyTarget() },` after the `currentGoal:` argument.
- `RunnerTests/SyncCoordinatorTests.swift:27` — add `currentWeeklyTarget: { 3 },` after the `currentGoal:` argument.

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test -only-testing:RunnerTests/LedgerBuilderTests -only-testing:RunnerTests/DataStoreTests -only-testing:RunnerTests/SyncCoordinatorTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add Runner/Core/Store/Models.swift Runner/Core/PointsEngine/LedgerBuilder.swift Runner/Core/Store/DataStore.swift Runner/Core/Store/SyncCoordinator.swift Runner/App/AppModel.swift RunnerTests/LedgerBuilderTests.swift RunnerTests/DataStoreTests.swift RunnerTests/SyncCoordinatorTests.swift
git commit -m "feat: snapshot weeklyTargetAtThatTime on DayLedger (migration-safe inline default)"
```

---

### Task 4: `GoalsMath` engine — current week, completed weeks, streak

**Files:**
- Create: `Runner/Features/Shared/GoalsMath.swift`
- Test: `RunnerTests/GoalsMathTests.swift` (new)

**Interfaces:**
- Consumes: `WeekMath.mondayStart(for:calendar:)` (Task 1).
- Produces (used by Tasks 5, 6, 7):
  - `struct GoalLedgerDay { let date: Date; let isGold: Bool; let weeklyTarget: Int }`
  - `enum GoalDotState { case gold, missed, future }`
  - `struct WeeklyGoalStatus: Equatable { goldDays: Int; target: Int; dots: [GoalDotState]; isMet: Bool; streak: Int }`
  - `struct CompletedWeek: Equatable { weekStart: Date; completedOn: Date }`
  - `GoalsMath.currentWeek(_:currentTarget:asOf:calendar:) -> WeeklyGoalStatus`
  - `GoalsMath.completedWeeks(_:calendar:) -> [CompletedWeek]`

Semantics (from the spec):
- Current week: gold days so far vs the **live** target; 7 Monday-first dots (`.gold` = ledgered gold day, `.missed` = past-or-today non-gold, `.future` = after `asOf`'s day).
- A week is *completed* when its unique gold-day count ≥ the `weeklyTarget` snapshot of its **latest ledgered day**; `completedOn` = the date of the target-th gold day (chronological) — this powers retroactive trophy minting.
- Streak: consecutive completed weeks walking back Monday-by-Monday from the week before the current week; the current week adds 1 **only once completed**; any gap week (no completed entry — including zero-ledger weeks) breaks it.

- [ ] **Step 1: Write the failing tests**

Create `RunnerTests/GoalsMathTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

struct GoalsMathTests {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(timeZone: cal.timeZone,
                                      year: year, month: month, day: day, hour: hour))!
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, gold: Bool, target: Int = 3) -> GoalLedgerDay {
        GoalLedgerDay(date: date(y, m, d), isGold: gold, weeklyTarget: target)
    }

    // Reference week: Monday 2026-07-06 ... Sunday 2026-07-12.

    @Test func currentWeekCountsGoldDaysAndDots() {
        let days = [day(2026, 7, 6, gold: true),    // Mon gold
                    day(2026, 7, 7, gold: false),   // Tue missed
                    day(2026, 7, 8, gold: true)]    // Wed gold
        let status = GoalsMath.currentWeek(days, currentTarget: 3,
                                           asOf: date(2026, 7, 9), calendar: cal) // Thu
        #expect(status.goldDays == 2)
        #expect(status.target == 3)
        #expect(status.isMet == false)
        #expect(status.dots == [.gold, .missed, .gold, .missed, .future, .future, .future])
    }

    @Test func currentWeekMetUsesLiveTarget() {
        // Snapshots say 5, but the live target is 2 — the current week judges at 2.
        let days = [day(2026, 7, 6, gold: true, target: 5),
                    day(2026, 7, 7, gold: true, target: 5)]
        let status = GoalsMath.currentWeek(days, currentTarget: 2,
                                           asOf: date(2026, 7, 8), calendar: cal)
        #expect(status.isMet == true)
        #expect(status.streak == 1) // current week counts once completed
    }

    @Test func completedWeeksJudgeByLatestSnapshot() {
        // Mid-week target change: early days snapshot 2, the latest day snapshots 3.
        // Only 2 gold days -> the week is NOT completed at target 3.
        let raised = [day(2026, 6, 29, gold: true, target: 2),
                      day(2026, 6, 30, gold: true, target: 2),
                      day(2026, 7, 3, gold: false, target: 3)]
        #expect(GoalsMath.completedWeeks(raised, calendar: cal).isEmpty)

        // Same week but the latest day still says 2 -> completed, on the 2nd gold day.
        let kept = [day(2026, 6, 29, gold: true, target: 2),
                    day(2026, 6, 30, gold: true, target: 2)]
        let weeks = GoalsMath.completedWeeks(kept, calendar: cal)
        #expect(weeks.count == 1)
        #expect(weeks[0].weekStart == cal.startOfDay(for: date(2026, 6, 29)))
        #expect(weeks[0].completedOn == cal.startOfDay(for: date(2026, 6, 30)))
    }

    @Test func streakBuildsAcrossConsecutiveWeeksAndSurvivesUnfinishedCurrentWeek() {
        // Weeks of Jun 22 and Jun 29 completed (target 1); current week (Jul 6) not yet.
        let days = [day(2026, 6, 24, gold: true, target: 1),
                    day(2026, 6, 30, gold: true, target: 1),
                    day(2026, 7, 6, gold: false, target: 1)]
        let status = GoalsMath.currentWeek(days, currentTarget: 1,
                                           asOf: date(2026, 7, 7), calendar: cal)
        // Unfinished current week does not break the streak, and does not extend it.
        #expect(status.streak == 2)
    }

    @Test func emptyWeekBreaksStreak() {
        // Week of Jun 22 completed, week of Jun 29 has NO ledger days, current week completed.
        let days = [day(2026, 6, 24, gold: true, target: 1),
                    day(2026, 7, 6, gold: true, target: 1)]
        let status = GoalsMath.currentWeek(days, currentTarget: 1,
                                           asOf: date(2026, 7, 7), calendar: cal)
        #expect(status.streak == 1) // only the current week
    }

    @Test func completedWeeksSortedByWeekStart() {
        let days = [day(2026, 7, 6, gold: true, target: 1),
                    day(2026, 6, 22, gold: true, target: 1)]
        let weeks = GoalsMath.completedWeeks(days, calendar: cal)
        #expect(weeks.map(\.weekStart) == [cal.startOfDay(for: date(2026, 6, 22)),
                                           cal.startOfDay(for: date(2026, 7, 6))])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test -only-testing:RunnerTests/GoalsMathTests 2>&1 | tail -20`
Expected: BUILD FAILURE — `cannot find 'GoalsMath' in scope`.

- [ ] **Step 3: Implement `Runner/Features/Shared/GoalsMath.swift`**

```swift
import Foundation

/// Minimal DayLedger projection consumed by GoalsMath.
struct GoalLedgerDay: Equatable, Sendable {
    let date: Date
    let isGold: Bool
    /// DayLedger.weeklyTargetAtThatTime — the target in effect when the day was ledgered.
    let weeklyTarget: Int
}

enum GoalDotState: Equatable, Sendable {
    case gold
    case missed
    case future
}

struct WeeklyGoalStatus: Equatable, Sendable {
    let goldDays: Int
    let target: Int
    /// Exactly 7 entries, Monday first.
    let dots: [GoalDotState]
    let isMet: Bool
    /// Consecutive completed weeks; the current week counts once completed.
    let streak: Int
}

struct CompletedWeek: Equatable, Sendable {
    /// Monday start-of-day of the completed week.
    let weekStart: Date
    /// The day the target-th gold day landed — when the week's goal was met.
    let completedOn: Date
}

enum GoalsMath {
    static func currentWeek(_ days: [GoalLedgerDay],
                            currentTarget: Int,
                            asOf: Date,
                            calendar: Calendar) -> WeeklyGoalStatus {
        let weekStart = WeekMath.mondayStart(for: asOf, calendar: calendar)
        let today = calendar.startOfDay(for: asOf)
        let goldDates = Set(days.filter(\.isGold).map { calendar.startOfDay(for: $0.date) })

        var dots: [GoalDotState] = []
        var goldDays = 0
        for offset in 0..<7 {
            let dayDate = calendar.date(byAdding: .day, value: offset, to: weekStart)!
            if dayDate > today {
                dots.append(.future)
            } else if goldDates.contains(dayDate) {
                dots.append(.gold)
                goldDays += 1
            } else {
                dots.append(.missed)
            }
        }

        let isMet = goldDays >= currentTarget
        let completed = Set(completedWeeks(days, calendar: calendar).map(\.weekStart))
        var streak = isMet ? 1 : 0
        var week = calendar.date(byAdding: .day, value: -7, to: weekStart)!
        while completed.contains(week) {
            streak += 1
            week = calendar.date(byAdding: .day, value: -7, to: week)!
        }

        return WeeklyGoalStatus(goldDays: goldDays, target: currentTarget,
                                dots: dots, isMet: isMet, streak: streak)
    }

    /// Every week whose unique gold days reached the weeklyTarget snapshot of its
    /// latest ledgered day. Judged from snapshots, so raising the target later
    /// never rewrites history.
    static func completedWeeks(_ days: [GoalLedgerDay], calendar: Calendar) -> [CompletedWeek] {
        let byWeek = Dictionary(grouping: days) { WeekMath.mondayStart(for: $0.date, calendar: calendar) }
        return byWeek.compactMap { weekStart, weekDays -> CompletedWeek? in
            guard let latest = weekDays.max(by: { $0.date < $1.date }) else { return nil }
            let target = max(latest.weeklyTarget, 1)
            let goldDates = Set(weekDays.filter(\.isGold).map { calendar.startOfDay(for: $0.date) }).sorted()
            guard goldDates.count >= target else { return nil }
            return CompletedWeek(weekStart: weekStart, completedOn: goldDates[target - 1])
        }
        .sorted { $0.weekStart < $1.weekStart }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2.
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Runner/Features/Shared/GoalsMath.swift RunnerTests/GoalsMathTests.swift
git commit -m "feat: GoalsMath pure engine (current-week dots, completed weeks, weekly streak)"
```

---

### Task 5: Weekly trophy badges in `TrophyMath`

**Files:**
- Modify: `Runner/Features/Trophies/TrophyMath.swift` (BadgeKind at lines 3-6; new static func in the `TrophyMath` enum)
- Test: `RunnerTests/TrophyMathTests.swift` (add tests)

**Interfaces:**
- Consumes: `CompletedWeek` (Task 4).
- Produces: `BadgeKind.weeklyGoal`, `BadgeKind.weeklyStreak`, `TrophyMath.weeklyBadges(_ weeks: [CompletedWeek], calendar: Calendar) -> [Badge]` — consumed by Task 6. Badge IDs come out as `"weeklyGoal.global.1"`, `"weeklyStreak.global.4"`, `"weeklyStreak.global.12"` (the existing `badgeID` scheme; distinct from all existing `distance.*`/`count.*` IDs, so `TrophySeenStore` needs no change).

Badges (all scope `.global`):
- **First weekly goal met** — `weeklyGoal`, threshold 1, earned when ≥ 1 completed week; `earnedAt` = first week's `completedOn`.
- **4-week streak** and **12-week streak** — `weeklyStreak`, thresholds 4 and 12, earned from the longest run of consecutive `weekStart`s (7-day steps); `earnedAt` = `completedOn` of the week where the run first reached the threshold. Progress toward the next unearned streak badge = longest run / threshold (monotonic, like the existing cumulative totals).

- [ ] **Step 1: Write the failing tests**

Add to `RunnerTests/TrophyMathTests.swift` (reuse the file's calendar/date helpers if present; otherwise add the standard Gregorian/Toronto pair used by `GoalsMathTests`):

```swift
    private func week(_ y: Int, _ m: Int, _ d: Int) -> CompletedWeek {
        // d must be a Monday; completedOn = Wednesday of that week.
        let cal = self.cal
        let start = cal.startOfDay(for: date(y, m, d))
        return CompletedWeek(weekStart: start,
                             completedOn: cal.date(byAdding: .day, value: 2, to: start)!)
    }

    @Test func weeklyBadgesEmptyStateAllUnearned() {
        let badges = TrophyMath.weeklyBadges([], calendar: cal)
        #expect(badges.count == 3)
        #expect(badges.allSatisfy { !$0.earned })
        #expect(badges.map(\.id) == ["weeklyGoal.global.1", "weeklyStreak.global.4", "weeklyStreak.global.12"])
    }

    @Test func firstWeeklyGoalMintsWithEarnedDate() {
        let w = week(2026, 6, 22)
        let badges = TrophyMath.weeklyBadges([w], calendar: cal)
        let first = badges.first { $0.id == "weeklyGoal.global.1" }!
        #expect(first.earned)
        #expect(first.earnedAt == w.completedOn)
    }

    @Test func fourWeekStreakNeedsConsecutiveMondays() {
        // Mondays 2026: Jun 1, Jun 8, Jun 15, Jun 22 — consecutive.
        let run = [week(2026, 6, 1), week(2026, 6, 8), week(2026, 6, 15), week(2026, 6, 22)]
        let badges = TrophyMath.weeklyBadges(run, calendar: cal)
        let streak4 = badges.first { $0.id == "weeklyStreak.global.4" }!
        #expect(streak4.earned)
        #expect(streak4.earnedAt == run[3].completedOn)

        // A gap (missing Jun 15) resets the run — only 2-in-a-row max.
        let gapped = [week(2026, 6, 1), week(2026, 6, 8), week(2026, 6, 22), week(2026, 6, 29)]
        let broken = TrophyMath.weeklyBadges(gapped, calendar: cal)
        #expect(broken.first { $0.id == "weeklyStreak.global.4" }!.earned == false)
        #expect(broken.first { $0.id == "weeklyStreak.global.4" }!.progress == 0.5)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test -only-testing:RunnerTests/TrophyMathTests 2>&1 | tail -20`
Expected: BUILD FAILURE — `type 'TrophyMath' has no member 'weeklyBadges'`.

- [ ] **Step 3: Implement**

In `Runner/Features/Trophies/TrophyMath.swift`, extend `BadgeKind`:

```swift
enum BadgeKind: String, Sendable {
    case distance
    case count
    case weeklyGoal
    case weeklyStreak
}
```

Add inside `enum TrophyMath`:

```swift
    private static let weeklyStreakThresholds = [4.0, 12]

    /// Weekly consistency badges, derived from GoalsMath.completedWeeks over all
    /// history — past qualifying weeks mint retroactively, like the Trophy Room backfill.
    static func weeklyBadges(_ weeks: [CompletedWeek], calendar: Calendar) -> [Badge] {
        let sorted = weeks.sorted { $0.weekStart < $1.weekStart }

        var longest = 0
        var run = 0
        var previous: Date?
        var streakEarnedAt: [Double: Date] = [:]
        for week in sorted {
            if let previous, calendar.date(byAdding: .day, value: 7, to: previous) == week.weekStart {
                run += 1
            } else {
                run = 1
            }
            previous = week.weekStart
            longest = max(longest, run)
            for threshold in weeklyStreakThresholds
            where run == Int(threshold) && streakEarnedAt[threshold] == nil {
                streakEarnedAt[threshold] = week.completedOn
            }
        }

        let firstID = badgeID(kind: .weeklyGoal, scope: .global, threshold: 1)
        var badges = [Badge(id: firstID,
                            kind: .weeklyGoal,
                            scope: .global,
                            threshold: 1,
                            earned: !sorted.isEmpty,
                            progress: sorted.isEmpty ? 0 : 1,
                            earnedAt: sorted.first?.completedOn)]

        let nextUnearned = weeklyStreakThresholds.first { Double(longest) < $0 }
        badges += weeklyStreakThresholds.map { threshold in
            let earned = Double(longest) >= threshold
            let progress: Double
            if earned {
                progress = 1
            } else if threshold == nextUnearned {
                progress = min(max(Double(longest) / threshold, 0), 1)
            } else {
                progress = 0
            }
            return Badge(id: badgeID(kind: .weeklyStreak, scope: .global, threshold: threshold),
                         kind: .weeklyStreak,
                         scope: .global,
                         threshold: threshold,
                         earned: earned,
                         progress: progress,
                         earnedAt: streakEarnedAt[threshold])
        }
        return badges
    }
```

Note: `TrophyBadgeCell.title` in `TrophyRoomView.swift` switches exhaustively on `BadgeKind` — adding the cases will break its build. Add the two cases now (they ship for real in Task 6):

```swift
        case .weeklyGoal: String(localized: "First weekly goal")
        case .weeklyStreak: String(format: String(localized: "%lld-week streak"), Int64(badge.threshold))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2.
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Runner/Features/Trophies/TrophyMath.swift Runner/Features/Trophies/TrophyRoomView.swift RunnerTests/TrophyMathTests.swift
git commit -m "feat: weekly-goal trophy badges (first weekly goal, 4- and 12-week streaks)"
```

---

### Task 6: Trophy Room UI — Weekly goals section + HistoryView wiring

**Files:**
- Modify: `Runner/Features/Trophies/TrophyRoomView.swift`
- Modify: `Runner/Features/History/HistoryView.swift` (entry card ~line 324-330, call site ~line 59, computed props near line 12-18)
- Modify: `Runner/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `TrophyMath.weeklyBadges(_:calendar:)` (Task 5), `GoalsMath.completedWeeks(_:calendar:)` + `GoalLedgerDay` (Task 4), `DayLedger.weeklyTargetAtThatTime` (Task 3).
- Produces: `TrophyRoomView(summaries:goalWeeks:)` — new required `goalWeeks: [CompletedWeek]` parameter.

Views are not unit-tested in this repo (math is); verification is build + the existing suites still passing.

- [ ] **Step 1: TrophyRoomView — accept goal weeks and render the section**

Replace the top of `TrophyRoomView` and its body sections:

```swift
struct TrophyRoomView: View {
    let summaries: [ActivityWorkoutSummary]
    let goalWeeks: [CompletedWeek]
    private let seenStore = TrophySeenStore()

    private var activityBadges: [Badge] {
        TrophyMath.allBadges(summaries)
    }

    private var weeklyBadges: [Badge] {
        TrophyMath.weeklyBadges(goalWeeks, calendar: .current)
    }

    private var badges: [Badge] {
        activityBadges + weeklyBadges
    }
```

In `body`, add a weekly section as the first entry of the `VStack`, above the Global section:

```swift
                weeklyGoalsSection
```

Change `badgeSection`'s filter to use `activityBadges` (so weekly `.global` badges don't leak into the Global grid):

```swift
                ForEach(activityBadges.filter { $0.scope == scope }) { badge in
```

Add the section (mirrors `badgeSection`):

```swift
    private var weeklyGoalsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: String(localized: "Weekly goals"))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(weeklyBadges) { badge in
                    TrophyBadgeCell(badge: badge,
                                    accent: .rLime,
                                    isUnseen: badge.earned && !seenStore.isSeen(badge.id))
                }
            }
        }
    }
```

`onAppear`'s `seenStore.markSeen(badges.filter(\.earned).map(\.id))` already covers the combined array — leave it.

- [ ] **Step 2: HistoryView — project ledgers and thread goalWeeks through**

Near the other computed props (~line 12-18) add:

```swift
    private var goalWeeks: [CompletedWeek] {
        GoalsMath.completedWeeks(
            ledgers.map { GoalLedgerDay(date: $0.date, isGold: $0.isGold,
                                        weeklyTarget: $0.weeklyTargetAtThatTime) },
            calendar: .current)
    }
```

Change the entry-card call site (~line 59) to `trophyRoomEntryCard(summaries: summaries, goalWeeks: goalWeeks)` and the card itself:

```swift
    private func trophyRoomEntryCard(summaries: [ActivityWorkoutSummary],
                                     goalWeeks: [CompletedWeek]) -> some View {
        let badges = TrophyMath.allBadges(summaries) + TrophyMath.weeklyBadges(goalWeeks, calendar: .current)
        let earnedCount = badges.filter(\.earned).count
        let next = TrophyMath.nextMilestone(summaries)

        return NavigationLink {
            TrophyRoomView(summaries: summaries, goalWeeks: goalWeeks)
        } label: {
            ...unchanged label...
        }
    }
```

Fix any other `TrophyRoomView(` construction site: `rg -n "TrophyRoomView\(" Runner` — pass `goalWeeks: []` only in previews, real call sites must pass real projections.

- [ ] **Step 3: Localization entries**

Add to `Runner/Resources/Localizable.xcstrings` (alphabetical position):

```json
    "%lld-week streak": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Série de %lld semaines"
          }
        }
      }
    },
```
```json
    "First weekly goal": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Premier objectif hebdo"
          }
        }
      }
    },
```
```json
    "Weekly goals": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Objectifs hebdomadaires"
          }
        }
      }
    },
```

- [ ] **Step 4: Build and run the trophy suites**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test -only-testing:RunnerTests/TrophyMathTests -only-testing:RunnerTests/TrophySeenStoreTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Runner/Features/Trophies/TrophyRoomView.swift Runner/Features/History/HistoryView.swift Runner/Resources/Localizable.xcstrings
git commit -m "feat: Weekly goals section in Trophy Room, wired from ledger projections"
```

---

### Task 7: Today weekly-goal row + completion celebration

**Files:**
- Create: `Runner/Features/Today/WeeklyGoalRow.swift`
- Modify: `Runner/Features/Today/TodayView.swift` (pointsBlock ~line 124-152; celebration onChange ~line 87-100; computed props)
- Modify: `Runner/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `GoalsMath.currentWeek(_:currentTarget:asOf:calendar:)`, `WeeklyGoalStatus`, `GoalDotState` (Task 4); `model.weeklyGoldTarget` (Task 2); existing `celebrate` @State + `CelebrationBurst` overlay in TodayView.

- [ ] **Step 1: Create `Runner/Features/Today/WeeklyGoalRow.swift`**

```swift
import SwiftUI

struct WeeklyGoalRow: View {
    let status: WeeklyGoalStatus

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(Array(status.dots.enumerated()), id: \.offset) { _, dot in
                    dotView(dot)
                }
            }
            Text(String(format: String(localized: "%d of %d this week"),
                        status.goldDays, status.target))
                .font(.caption)
                .foregroundStyle(status.isMet ? Color.rLime : Color.rTextSecondary)
            Spacer()
            if status.streak >= 2 {
                Text(String(format: String(localized: "%lld-week streak"), Int64(status.streak)))
                    .font(.caption.bold())
                    .foregroundStyle(Color.rLime)
            }
        }
    }

    @ViewBuilder
    private func dotView(_ dot: GoalDotState) -> some View {
        switch dot {
        case .gold:
            Circle().fill(Color.rLime).frame(width: 8, height: 8)
        case .missed:
            Circle().stroke(Color.rTextSecondary, lineWidth: 1).frame(width: 8, height: 8)
        case .future:
            Circle().fill(Color.rTextSecondary.opacity(0.25)).frame(width: 8, height: 8)
        }
    }
}
```

- [ ] **Step 2: Wire into TodayView**

Add computed props next to the existing ones (~line 16-27):

```swift
    private var weeklyStatus: WeeklyGoalStatus {
        GoalsMath.currentWeek(
            ledgers.map { GoalLedgerDay(date: $0.date, isGold: $0.isGold,
                                        weeklyTarget: $0.weeklyTargetAtThatTime) },
            currentTarget: model.weeklyGoldTarget,
            asOf: .now,
            calendar: .current)
    }
```

In `pointsBlock`, directly after the `Text(String(localized: "Goal: \(model.dailyGoal) pts"))` line, add:

```swift
            WeeklyGoalRow(status: weeklyStatus)
```

- [ ] **Step 3: Celebration on the week's false→true transition**

Directly below the existing daily `.onChange(of: today?.isGold ?? false)` modifier (~line 92-100), add a weekly one that reuses the same `celebrate` flag — the guard `!celebrate` prevents a double burst/haptic when today's gold flip simultaneously completes the week (spec: "guarded so daily and weekly bursts don't double-fire in the same render"):

```swift
        .onChange(of: weeklyStatus.isMet) { was, isNow in
            if !was && isNow && !celebrate {
                celebrate = true
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    celebrate = false
                }
            }
        }
```

- [ ] **Step 4: Localization entry**

Add to `Runner/Resources/Localizable.xcstrings` (alphabetical position; `"%lld-week streak"` already exists from Task 6):

```json
    "%d of %d this week": {
      "localizations": {
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "%d sur %d cette semaine"
          }
        }
      }
    },
```

- [ ] **Step 5: Build**

Run: `xcodegen generate && xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Runner/Features/Today/WeeklyGoalRow.swift Runner/Features/Today/TodayView.swift Runner/Resources/Localizable.xcstrings
git commit -m "feat: Today weekly-goal row (day dots, week streak) with completion celebration"
```

---

### Task 8: Full-suite verification

**Files:** none new.

- [ ] **Step 1: Run the entire test suite**

Run: `xcodegen generate && xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, zero failures (~200+ tests).

- [ ] **Step 2: Placeholder / leftover scan**

Run: `rg -n "TODO|FIXME|placeholder" Runner/Features/Shared/GoalsMath.swift Runner/Features/Shared/WeekMath.swift Runner/Features/Today/WeeklyGoalRow.swift`
Expected: no output. Also `git status` — working tree clean (everything committed by prior tasks).

- [ ] **Step 3: Spec cross-check (Phase 1 rows only)**

Confirm each is done: weeklyGoldTarget setting ✓ (Task 2), DayLedger snapshot ✓ (Task 3), WeekMath extraction ✓ (Task 1), GoalsMath consistency + streak ✓ (Task 4), Today row + celebration ✓ (Task 7), trophy badges ✓ (Tasks 5-6), FR/EN strings ✓ (Tasks 2, 6, 7), tests ✓ (Tasks 1-5, 8).
