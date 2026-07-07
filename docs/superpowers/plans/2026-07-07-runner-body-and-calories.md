# Runner v1.1 — Body & Calories Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add body metrics (height/weight/age/sex), an estimated calories-burned metric, richer Today content (calories, distance, active time, 7-day trend), and a per-day detail screen — without changing the points engine.

**Architecture:** A new pure `CalorieEngine` (MET × weight × time, no sensors) mirrors the existing pure `PointsEngine`. A new `Core/Profile` resolves body metrics from HealthKit with local manual overrides stored in a single-row `UserProfile` (SwiftData). Calorie/distance/active-time are threaded into the existing `SyncCoordinator.performSync` recompute path and persisted as derived fields on `DayLedger`, plus a persisted `calories` on `WorkoutRec`. New SwiftUI screens (Profile, Day Detail) and Today additions consume these.

**Tech Stack:** Swift 6 / SwiftUI, SwiftData, HealthKit, Swift Charts, Swift Testing (`import Testing`, `@Test`, `#expect`). No third-party runtime dependencies.

## Global Constraints

- Swift 6 / SwiftUI, iOS 18.0 deployment target (`IPHONEOS_DEPLOYMENT_TARGET = 18.0`).
- Dark mode only ("Electric Night"). Colors via `Color.r*` tokens in `Runner/DesignSystem/Theme.swift` (`rBackground`, `rSurface`, `rBorder`, `rLime`, `rTeal`, `rPurple`, `rOrange`, `rTextSecondary`).
- No new third-party runtime dependencies. (The `xcodeproj` Ruby gem in Task 1 is build-time tooling only, never linked into the app.)
- **Points engine, streak, and multiplier rules are untouched.** `PointsEngine` and `LedgerBuilder` are not modified.
- SwiftData is a rebuildable cache over HealthKit: all `DayLedger` calorie/distance/time fields are **derived** and recomputed by `SyncCoordinator.performSync`. `WorkoutRec.calories` is persisted at save time from the body metrics in effect then.
- Calories are always **estimates**, labeled as such; shown as `nil`/empty state when weight is unknown — never a fabricated number.
- All user-facing strings use `String(localized:)`; French translations added to the String Catalog.
- Xcode project is the classic (non-synchronized) model, `objectVersion = 77`. Every new `.swift` file MUST be registered into `Runner.xcodeproj/project.pbxproj` (Task 1 provides the helper).
- Tests run with: `xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16'` (run `xcodebuild -list` / `xcrun simctl list devices available` first if that device name is not present, and substitute an available simulator).

---

### Task 1: Xcode project file-registration helper

New source files won't compile unless referenced in `project.pbxproj`. This task installs the `xcodeproj` gem and adds a tiny helper so every later task registers files with one command.

**Files:**
- Create: `scripts/xcadd.rb`

**Interfaces:**
- Produces: shell command `ruby scripts/xcadd.rb <file_path> <Runner|RunnerTests>` — adds the file to the named target's group + Sources build phase, idempotently.

- [ ] **Step 1: Install the tooling gem**

Run: `gem install xcodeproj` (if it fails on permissions, use `gem install --user-install xcodeproj`).
Expected: `Successfully installed xcodeproj-...`. If the environment has no network and the gem cannot be installed, fall back to adding files through Xcode's "Add Files to Runner…" GUI for each Create step below — the rest of the plan is unaffected.

- [ ] **Step 2: Write the helper script**

Create `scripts/xcadd.rb`:

```ruby
#!/usr/bin/env ruby
# Adds a source file to a target's group and Sources build phase, idempotently.
# Usage: ruby scripts/xcadd.rb <relative_file_path> <target_name>
require 'xcodeproj'

path = ARGV[0]
target_name = ARGV[1]
abort "usage: xcadd.rb <file> <target>" unless path && target_name

project = Xcodeproj::Project.open('Runner.xcodeproj')
target = project.targets.find { |t| t.name == target_name }
abort "target #{target_name} not found" unless target

# Already referenced? Bail out cleanly.
if project.files.any? { |f| f.real_path.to_s == File.expand_path(path) }
  puts "already present: #{path}"
  exit 0
end

# Walk/create the group chain matching the on-disk folders (drop leading target dir).
parts = path.split('/')
parts.shift # e.g. "Runner" or "RunnerTests"
filename = parts.pop
group = project.main_group.find_subpath(target_name, true)
parts.each { |p| group = group.find_subpath(p, true) }
group.set_source_tree('SOURCE_ROOT')

file_ref = group.new_reference(path)
target.add_file_references([file_ref])
project.save
puts "added: #{path} -> #{target_name}"
```

- [ ] **Step 3: Verify the helper round-trips**

Run: `ruby scripts/xcadd.rb Runner/App/RunnerApp.swift Runner` (an existing file).
Expected: prints `already present: Runner/App/RunnerApp.swift` and exits 0, and `git diff --stat Runner.xcodeproj/project.pbxproj` shows **no change** (idempotent on an existing file).

- [ ] **Step 4: Commit**

```bash
git add scripts/xcadd.rb
git commit -m "build: xcodeproj file-registration helper for new sources"
```

---

### Task 2: CalorieEngine (pure MET model)

The heart of v1.1: a pure, dependency-free estimator. No iOS imports, fully unit-tested like `PointsEngine`.

**Files:**
- Create: `Runner/Core/CalorieEngine/CalorieEngine.swift`
- Test: `RunnerTests/CalorieEngineTests.swift`

**Interfaces:**
- Consumes: `ActivityType` (from `Runner/DesignSystem/Theme.swift`).
- Produces:
  - `enum BodySex: String, Sendable { case male, female, unspecified }`
  - `struct BodyMetrics: Equatable, Sendable { let weightKg: Double?; let heightCm: Double?; let sex: BodySex; let age: Int? }`
  - `struct WorkoutEnergyInput: Equatable, Sendable { let type: ActivityType; let distanceMeters: Double; let movingSeconds: Double }`
  - `struct CalorieBreakdown: Equatable, Sendable { let everydayKcal: Double; let workoutKcal: [Double]; var total: Double }`
  - `enum CalorieEngine` with statics: `strideMeters(heightCm:sex:) -> Double`, `metersToSteps(distanceMeters:heightCm:sex:) -> Int`, `met(type:speedKmh:) -> Double`, `workoutCalories(type:distanceMeters:movingSeconds:weightKg:) -> Double`, `dayCalories(steps:workouts:metrics:) -> CalorieBreakdown?`.

- [ ] **Step 1: Write the failing tests**

Create `RunnerTests/CalorieEngineTests.swift`:

```swift
import Testing
@testable import Runner

struct CalorieEngineTests {
    // MET interpolation clamps at the ends and interpolates in the middle.
    @Test func runMETBreakpointsAndClamp() {
        #expect(abs(CalorieEngine.met(type: .run, speedKmh: 3.0) - 6.0) < 0.001)   // below floor → clamp low
        #expect(abs(CalorieEngine.met(type: .run, speedKmh: 9.7) - 9.8) < 0.001)   // exact breakpoint
        #expect(abs(CalorieEngine.met(type: .run, speedKmh: 40.0) - 19.0) < 0.001) // above top → clamp high
        let mid = CalorieEngine.met(type: .run, speedKmh: 8.85)                    // between 8.0 and 9.7
        #expect(mid > 8.3 && mid < 9.8)
    }

    @Test func walkAndBikeMET() {
        #expect(abs(CalorieEngine.met(type: .walk, speedKmh: 2.0) - 2.0) < 0.001)  // stroll floor
        #expect(abs(CalorieEngine.met(type: .walk, speedKmh: 5.6) - 4.3) < 0.001)
        #expect(abs(CalorieEngine.met(type: .bike, speedKmh: 10.0) - 4.0) < 0.001) // leisure floor
        #expect(abs(CalorieEngine.met(type: .bike, speedKmh: 22.5) - 10.0) < 0.001)
    }

    // Workout kcal = MET × weightKg × hours. 5 km run in 30 min = 10 km/h.
    @Test func workoutCaloriesRun() {
        let kcal = CalorieEngine.workoutCalories(type: .run, distanceMeters: 5000,
                                                 movingSeconds: 1800, weightKg: 70)
        // 10 km/h → MET ~9.87; 70 kg × 0.5 h → ~345 kcal.
        #expect(kcal > 320 && kcal < 370)
    }

    @Test func workoutCaloriesZeroGuards() {
        #expect(CalorieEngine.workoutCalories(type: .run, distanceMeters: 0, movingSeconds: 0, weightKg: 70) == 0)
        #expect(CalorieEngine.workoutCalories(type: .run, distanceMeters: 3000, movingSeconds: 0, weightKg: 70) == 0)
    }

    // Stride from height; fallback when height is nil.
    @Test func stride() {
        #expect(abs(CalorieEngine.strideMeters(heightCm: 180, sex: .male) - 0.747) < 0.01)
        #expect(CalorieEngine.strideMeters(heightCm: nil, sex: .female) > 0.6)  // sex-based fallback
        #expect(CalorieEngine.strideMeters(heightCm: nil, sex: .male) > 0.7)
    }

    // No weight → nil (drives the empty state).
    @Test func nilWithoutWeight() {
        let m = BodyMetrics(weightKg: nil, heightCm: 180, sex: .male, age: 30)
        #expect(CalorieEngine.dayCalories(steps: 8000, workouts: [], metrics: m) == nil)
    }

    // Everyday steps are de-duplicated against run/walk workout steps; bike is not subtracted.
    @Test func dayCaloriesDeDuplicatesWorkoutSteps() {
        let m = BodyMetrics(weightKg: 70, heightCm: 180, sex: .male, age: 30)
        let run = WorkoutEnergyInput(type: .run, distanceMeters: 5000, movingSeconds: 1800)
        let withRun = CalorieEngine.dayCalories(steps: 12000, workouts: [run], metrics: m)!
        let stepsOnly = CalorieEngine.dayCalories(steps: 12000, workouts: [], metrics: m)!
        // The run's ~6600 steps are removed from everyday, so everyday kcal drops.
        #expect(withRun.everydayKcal < stepsOnly.everydayKcal)
        #expect(withRun.workoutKcal.count == 1 && withRun.workoutKcal[0] > 300)
        #expect(withRun.everydayKcal >= 0) // never negative

        // A bike ride does NOT subtract steps (no steps produced cycling).
        let bike = WorkoutEnergyInput(type: .bike, distanceMeters: 10000, movingSeconds: 1800)
        let withBike = CalorieEngine.dayCalories(steps: 12000, workouts: [bike], metrics: m)!
        #expect(abs(withBike.everydayKcal - stepsOnly.everydayKcal) < 0.001)
    }

    @Test func totalIsEverydayPlusWorkouts() {
        let m = BodyMetrics(weightKg: 68, heightCm: 172, sex: .female, age: 40)
        let w = WorkoutEnergyInput(type: .walk, distanceMeters: 3000, movingSeconds: 2400)
        let b = CalorieEngine.dayCalories(steps: 9000, workouts: [w], metrics: m)!
        #expect(abs(b.total - (b.everydayKcal + b.workoutKcal.reduce(0, +))) < 0.001)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RunnerTests/CalorieEngineTests`
Expected: FAIL — `CalorieEngine`, `BodyMetrics`, etc. are undefined (and the test file isn't in the target yet; add it in Step 3).

- [ ] **Step 3: Write the implementation**

Create `Runner/Core/CalorieEngine/CalorieEngine.swift`:

```swift
import Foundation

enum BodySex: String, Sendable {
    case male, female, unspecified
}

struct BodyMetrics: Equatable, Sendable {
    let weightKg: Double?
    let heightCm: Double?
    let sex: BodySex
    let age: Int?
}

struct WorkoutEnergyInput: Equatable, Sendable {
    let type: ActivityType
    let distanceMeters: Double
    let movingSeconds: Double
}

struct CalorieBreakdown: Equatable, Sendable {
    let everydayKcal: Double
    let workoutKcal: [Double]   // same order as the input workouts
    var total: Double { everydayKcal + workoutKcal.reduce(0, +) }
}

/// Pure energy-expenditure estimator. MET × body-mass × time, no heart-rate sensor.
/// Values are estimates; callers label them as such and never show them without a weight.
enum CalorieEngine {
    // Everyday (non-workout) step assumptions.
    static let everydayWalkMET = 3.0
    static let everydayWalkSpeedKmh = 4.5

    // Speed→MET breakpoints (km/h, MET), from the Compendium of Physical Activities.
    // Piecewise-linear, clamped at both ends.
    private static let runTable: [(Double, Double)] = [
        (6.4, 6.0), (8.0, 8.3), (9.7, 9.8), (11.3, 11.0),
        (12.9, 11.8), (14.5, 12.8), (16.1, 14.5), (19.3, 19.0),
    ]
    private static let walkTable: [(Double, Double)] = [
        (2.0, 2.0), (3.2, 2.8), (4.0, 3.0), (4.8, 3.5),
        (5.6, 4.3), (6.4, 5.0), (7.2, 6.3),
    ]
    private static let bikeTable: [(Double, Double)] = [
        (16.0, 4.0), (19.0, 8.0), (22.5, 10.0), (25.5, 12.0), (30.6, 15.8),
    ]

    private static func table(for type: ActivityType) -> [(Double, Double)] {
        switch type {
        case .run: runTable
        case .walk: walkTable
        case .bike: bikeTable
        }
    }

    static func met(type: ActivityType, speedKmh: Double) -> Double {
        let t = table(for: type)
        if speedKmh <= t.first!.0 { return t.first!.1 }
        if speedKmh >= t.last!.0 { return t.last!.1 }
        for i in 1..<t.count where speedKmh <= t[i].0 {
            let (x0, y0) = t[i - 1]
            let (x1, y1) = t[i]
            let f = (speedKmh - x0) / (x1 - x0)
            return y0 + f * (y1 - y0)
        }
        return t.last!.1
    }

    /// Stride length in meters. Height × sex factor; sex-based average when height is unknown.
    static func strideMeters(heightCm: Double?, sex: BodySex) -> Double {
        let factor: Double = switch sex {
        case .male: 0.415
        case .female: 0.413
        case .unspecified: 0.414
        }
        let h = heightCm ?? (sex == .female ? 162.0 : sex == .male ? 175.0 : 170.0)
        return (h / 100.0) * factor
    }

    static func metersToSteps(distanceMeters: Double, heightCm: Double?, sex: BodySex) -> Int {
        let stride = strideMeters(heightCm: heightCm, sex: sex)
        guard stride > 0 else { return 0 }
        return Int((distanceMeters / stride).rounded())
    }

    static func workoutCalories(type: ActivityType, distanceMeters: Double,
                                movingSeconds: Double, weightKg: Double) -> Double {
        guard distanceMeters > 0, movingSeconds > 0, weightKg > 0 else { return 0 }
        let speedKmh = (distanceMeters / 1000.0) / (movingSeconds / 3600.0)
        return met(type: type, speedKmh: speedKmh) * weightKg * (movingSeconds / 3600.0)
    }

    private static func kcalPerStep(weightKg: Double, stride: Double) -> Double {
        // Treat each step as everyday-pace walking: MET × weight × (strideKm / speedKmh) hours.
        (stride / 1000.0) * everydayWalkMET * weightKg / everydayWalkSpeedKmh
    }

    /// Full day breakdown, or nil when weight is unknown.
    static func dayCalories(steps: Int, workouts: [WorkoutEnergyInput],
                            metrics: BodyMetrics) -> CalorieBreakdown? {
        guard let weightKg = metrics.weightKg, weightKg > 0 else { return nil }

        let workoutKcal = workouts.map {
            workoutCalories(type: $0.type, distanceMeters: $0.distanceMeters,
                            movingSeconds: $0.movingSeconds, weightKg: weightKg)
        }

        // De-duplicate: remove steps attributable to run/walk workouts (bike has none).
        let workoutFootMeters = workouts
            .filter { $0.type != .bike }
            .reduce(0.0) { $0 + $1.distanceMeters }
        let workoutSteps = metersToSteps(distanceMeters: workoutFootMeters,
                                         heightCm: metrics.heightCm, sex: metrics.sex)
        let everydaySteps = max(0, steps - workoutSteps)
        let stride = strideMeters(heightCm: metrics.heightCm, sex: metrics.sex)
        let everydayKcal = Double(everydaySteps) * kcalPerStep(weightKg: weightKg, stride: stride)

        return CalorieBreakdown(everydayKcal: everydayKcal, workoutKcal: workoutKcal)
    }
}
```

- [ ] **Step 4: Register both files and run the tests**

```bash
ruby scripts/xcadd.rb Runner/Core/CalorieEngine/CalorieEngine.swift Runner
ruby scripts/xcadd.rb RunnerTests/CalorieEngineTests.swift RunnerTests
```
Run: `xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RunnerTests/CalorieEngineTests`
Expected: PASS (all `CalorieEngineTests`).

- [ ] **Step 5: Commit**

```bash
git add Runner/Core/CalorieEngine RunnerTests/CalorieEngineTests.swift Runner.xcodeproj/project.pbxproj
git commit -m "feat: CalorieEngine — pure MET-based calorie estimator"
```

---

### Task 3: Data model — UserProfile, WorkoutRec.calories, DayLedger derived fields

Additive SwiftData changes, all cache-safe. Register `UserProfile` in the container and default new fields so existing stores migrate lightly.

**Files:**
- Modify: `Runner/Core/Store/Models.swift`
- Modify: `Runner/Core/Store/DataStore.swift`
- Test: `RunnerTests/DataStoreTests.swift` (add cases)

**Interfaces:**
- Consumes: `BodySex` (Task 2).
- Produces:
  - `@Model UserProfile` (single row): `heightCm: Double?`, `isHeightManual: Bool`, `weightKg: Double?`, `isWeightManual: Bool`, `birthDate: Date?`, `isBirthManual: Bool`, `sexRaw: String?`, `isSexManual: Bool`.
  - `WorkoutRec.calories: Double`.
  - `DayLedger.activeCalories: Double`, `.distanceMeters: Double`, `.activeSeconds: Double`.
  - `struct DayDerived: Sendable { let activeCalories: Double; let distanceMeters: Double; let activeSeconds: Double }`.
  - `DataStore.profile() throws -> UserProfile` (get-or-create single row).
  - `DataStore.upsert(_ days: [LedgerDay], derived: [Date: DayDerived]) throws` (new `derived` param, defaulted).
  - `DataStore.upsertWorkout(... , calories: Double, ...)` (new `calories` param).

- [ ] **Step 1: Write the failing tests**

Add to `RunnerTests/DataStoreTests.swift` (inside the existing test struct):

```swift
@Test @MainActor func profileIsSingletonAndPersists() throws {
    let store = try DataStore(inMemory: true)
    let p1 = try store.profile()
    p1.weightKg = 72
    p1.isWeightManual = true
    try store.save()
    let p2 = try store.profile()
    #expect(p2.weightKg == 72)
    #expect(p2.isWeightManual == true)
    // Still exactly one row.
    #expect(try store.profileCount() == 1)
}

@Test @MainActor func upsertWritesDerivedDayFields() throws {
    let store = try DataStore(inMemory: true)
    let date = Calendar.current.startOfDay(for: .now)
    let day = LedgerDay(date: date, steps: 5000,
                        breakdown: PointsEngine.breakdown(steps: 5000, workouts: [], streakBefore: 0),
                        goal: 100, isGold: false, streakAfter: 0)
    try store.upsert([day], derived: [date: DayDerived(activeCalories: 210, distanceMeters: 4200, activeSeconds: 1800)])
    let row = try store.ledger(on: date)
    #expect(row?.activeCalories == 210)
    #expect(row?.distanceMeters == 4200)
    #expect(row?.activeSeconds == 1800)
}
```

Add a tiny `save()` and `profileCount()` helper expectation — they're implemented in Step 3.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RunnerTests/DataStoreTests`
Expected: FAIL — `UserProfile`, `store.profile()`, `DayDerived`, and the `derived:` overload don't exist.

- [ ] **Step 3: Implement the model + store changes**

In `Runner/Core/Store/Models.swift`, add fields to `DayLedger` and `WorkoutRec`, and add `UserProfile`.

DayLedger — add three stored properties and extend `init` + `apply`:

```swift
    var activeCalories: Double
    var distanceMeters: Double
    var activeSeconds: Double
```

Update `DayLedger.init` to accept and assign them with defaults:

```swift
    init(date: Date, steps: Int, stepPoints: Int, workoutPoints: Int, multiplier: Double,
         totalPoints: Int, goalAtThatTime: Int, isGold: Bool, streakAfter: Int,
         activeCalories: Double = 0, distanceMeters: Double = 0, activeSeconds: Double = 0) {
        // ... existing assignments ...
        self.activeCalories = activeCalories
        self.distanceMeters = distanceMeters
        self.activeSeconds = activeSeconds
    }
```

(Leave `apply(_:)` as-is — points fields only; derived fields are set separately in `upsert`.)

WorkoutRec — add `var calories: Double` and extend its `init` with `calories: Double = 0` assigned to `self.calories`.

Append the new model:

```swift
@Model
final class UserProfile {
    var heightCm: Double?
    var isHeightManual: Bool
    var weightKg: Double?
    var isWeightManual: Bool
    var birthDate: Date?
    var isBirthManual: Bool
    var sexRaw: String?
    var isSexManual: Bool

    init(heightCm: Double? = nil, isHeightManual: Bool = false,
         weightKg: Double? = nil, isWeightManual: Bool = false,
         birthDate: Date? = nil, isBirthManual: Bool = false,
         sexRaw: String? = nil, isSexManual: Bool = false) {
        self.heightCm = heightCm
        self.isHeightManual = isHeightManual
        self.weightKg = weightKg
        self.isWeightManual = isWeightManual
        self.birthDate = birthDate
        self.isBirthManual = isBirthManual
        self.sexRaw = sexRaw
        self.isSexManual = isSexManual
    }

    var sex: BodySex {
        get { sexRaw.flatMap(BodySex.init(rawValue:)) ?? .unspecified }
        set { sexRaw = newValue == .unspecified ? nil : newValue.rawValue }
    }

    var age: Int? {
        guard let birthDate else { return nil }
        return Calendar.current.dateComponents([.year], from: birthDate, to: .now).year
    }

    var bodyMetrics: BodyMetrics {
        BodyMetrics(weightKg: weightKg, heightCm: heightCm, sex: sex, age: age)
    }
}
```

In `Runner/Core/Store/DataStore.swift`:

Register the model and add `DayDerived` + helpers. Change the container line:

```swift
        container = try ModelContainer(for: DayLedger.self, WorkoutRec.self, UserProfile.self, configurations: config)
```

Add near the top of the file (after imports):

```swift
struct DayDerived: Sendable {
    let activeCalories: Double
    let distanceMeters: Double
    let activeSeconds: Double
}
```

Add profile accessors and a `save()` passthrough (inside the class):

```swift
    func save() throws { try context.save() }

    func profileCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<UserProfile>())
    }

    func profile() throws -> UserProfile {
        if let existing = try context.fetch(FetchDescriptor<UserProfile>()).first {
            return existing
        }
        let created = UserProfile()
        context.insert(created)
        try context.save()
        return created
    }
```

Change `upsert` to accept derived data and apply it. Replace the signature and the two write branches:

```swift
    func upsert(_ days: [LedgerDay], derived: [Date: DayDerived] = [:]) throws {
        guard !days.isEmpty else { return }
        let cal = Calendar.current
        let keys = days.map { cal.startOfDay(for: $0.date) }
        var byDay = Dictionary(uniqueKeysWithValues:
            try ledgers(from: keys.min()!, through: keys.max()!).map { ($0.date, $0) })
        for day in days {
            let key = cal.startOfDay(for: day.date)
            let row: DayLedger
            if let existing = byDay[key] {
                existing.apply(day)
                row = existing
            } else {
                let inserted = DayLedger(date: key,
                                         steps: day.steps,
                                         stepPoints: day.breakdown.stepPoints,
                                         workoutPoints: day.breakdown.workoutPoints,
                                         multiplier: day.breakdown.multiplier,
                                         totalPoints: day.breakdown.total,
                                         goalAtThatTime: day.goal,
                                         isGold: day.isGold,
                                         streakAfter: day.streakAfter)
                context.insert(inserted)
                byDay[key] = inserted
                row = inserted
            }
            if let d = derived[key] {
                row.activeCalories = d.activeCalories
                row.distanceMeters = d.distanceMeters
                row.activeSeconds = d.activeSeconds
            }
        }
        try context.save()
    }
```

Add a `calories` parameter to `upsertWorkout` (default `0`), assign it on both the create and update branches (`existing.calories = calories` / pass `calories: calories` into the `WorkoutRec(...)` initializer).

- [ ] **Step 4: Run tests to verify pass**

Run: `xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RunnerTests/DataStoreTests`
Expected: PASS. Then run the full suite to confirm nothing else broke:
`xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: PASS (existing call sites still compile because `calories` and `derived:` are defaulted).

- [ ] **Step 5: Commit**

```bash
git add Runner/Core/Store/Models.swift Runner/Core/Store/DataStore.swift RunnerTests/DataStoreTests.swift
git commit -m "feat: UserProfile model + derived calorie/distance/time fields"
```

---

### Task 4: Profile resolution (HealthKit read + manual override)

Read raw body metrics from HealthKit; merge them under manual overrides into the `UserProfile` row; expose synchronous `BodyMetrics` for the recompute path.

**Files:**
- Modify: `Runner/Core/Health/HealthStoring.swift`
- Modify: `Runner/Core/Health/HealthStore.swift`
- Modify: `RunnerTests/FakeHealthStore.swift`
- Create: `Runner/Core/Profile/ProfileStore.swift`
- Test: `RunnerTests/ProfileStoreTests.swift`

**Interfaces:**
- Consumes: `BodySex`, `BodyMetrics` (Task 2); `UserProfile`, `DataStore.profile()` (Task 3); `HealthStoring`.
- Produces:
  - `struct HealthBody: Sendable { let heightCm: Double?; let weightKg: Double?; let birthDate: Date?; let sex: BodySex }`
  - `HealthStoring.bodyMetrics() async throws -> HealthBody`
  - `@MainActor final class ProfileStore` with: `init(store:health:)`, `currentMetrics() -> BodyMetrics` (sync, reads the row), `refreshFromHealth() async` (fills non-manual fields from Health), `row() throws -> UserProfile`.

- [ ] **Step 1: Write the failing tests**

Create `RunnerTests/ProfileStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

@MainActor
struct ProfileStoreTests {
    private func makeStore() throws -> (DataStore, FakeHealthStore, ProfileStore) {
        let ds = try DataStore(inMemory: true)
        let hs = FakeHealthStore()
        return (ds, hs, ProfileStore(store: ds, health: hs))
    }

    @Test func healthFillsNonManualFields() async throws {
        let (_, hs, ps) = try makeStore()
        hs.cannedBody = HealthBody(heightCm: 178, weightKg: 74,
                                   birthDate: Calendar.current.date(byAdding: .year, value: -34, to: .now),
                                   sex: .male)
        await ps.refreshFromHealth()
        let m = ps.currentMetrics()
        #expect(m.weightKg == 74)
        #expect(m.heightCm == 178)
        #expect(m.sex == .male)
        #expect(m.age == 34)
    }

    @Test func manualOverrideWinsAndSurvivesRefresh() async throws {
        let (_, hs, ps) = try makeStore()
        hs.cannedBody = HealthBody(heightCm: 178, weightKg: 74, birthDate: nil, sex: .male)
        await ps.refreshFromHealth()
        let row = try ps.row()
        row.weightKg = 80
        row.isWeightManual = true
        // A later Health refresh must NOT clobber the manual weight.
        await ps.refreshFromHealth()
        #expect(ps.currentMetrics().weightKg == 80)
        // Non-manual height still tracks Health.
        #expect(ps.currentMetrics().heightCm == 178)
    }

    @Test func nilWhenHealthEmptyAndNoManual() async throws {
        let (_, hs, ps) = try makeStore()
        hs.cannedBody = HealthBody(heightCm: nil, weightKg: nil, birthDate: nil, sex: .unspecified)
        await ps.refreshFromHealth()
        #expect(ps.currentMetrics().weightKg == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RunnerTests/ProfileStoreTests`
Expected: FAIL — `HealthBody`, `bodyMetrics()`, `ProfileStore`, `cannedBody` undefined.

- [ ] **Step 3: Implement protocol, real store, fake, and ProfileStore**

In `Runner/Core/Health/HealthStoring.swift`, add the value type and protocol method:

```swift
struct HealthBody: Sendable {
    let heightCm: Double?
    let weightKg: Double?
    let birthDate: Date?
    let sex: BodySex
}
```

Add to the `HealthStoring` protocol:

```swift
    func bodyMetrics() async throws -> HealthBody
```

In `Runner/Core/Health/HealthStore.swift`:

Add characteristic/quantity types as stored properties:

```swift
    private let heightType = HKQuantityType(.height)
    private let bodyMassType = HKQuantityType(.bodyMass)
```

Extend `readTypes` to include body metrics:

```swift
    private var readTypes: Set<HKObjectType> {
        [stepType, workoutType, routeType, distanceWalkRun, distanceCycling,
         heightType, bodyMassType,
         HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex)]
    }
```

Implement the read (latest sample for quantities; characteristics are synchronous on `HKHealthStore`):

```swift
    func bodyMetrics() async throws -> HealthBody {
        async let heightM = latestQuantity(heightType, unit: .meterUnit(with: .centi))
        async let massKg = latestQuantity(bodyMassType, unit: .gramUnit(with: .kilo))
        let birth = try? store.dateOfBirthComponents().date
        let sex: BodySex = switch (try? store.biologicalSex().biologicalSex) ?? .notSet {
        case .male: .male
        case .female: .female
        default: .unspecified
        }
        return HealthBody(heightCm: try await heightM, weightKg: try await massKg,
                          birthDate: birth, sex: sex)
    }

    private func latestQuantity(_ type: HKQuantityType, unit: HKUnit) async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1,
                                      sortDescriptors: sort) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }
```

In `RunnerTests/FakeHealthStore.swift`, add a canned value and the method:

```swift
    var cannedBody = HealthBody(heightCm: nil, weightKg: nil, birthDate: nil, sex: .unspecified)
    func bodyMetrics() async throws -> HealthBody { cannedBody }
```

Create `Runner/Core/Profile/ProfileStore.swift`:

```swift
import Foundation

@MainActor
final class ProfileStore {
    private let store: DataStore
    private let health: HealthStoring

    init(store: DataStore, health: HealthStoring) {
        self.store = store
        self.health = health
    }

    func row() throws -> UserProfile { try store.profile() }

    func currentMetrics() -> BodyMetrics {
        (try? store.profile())?.bodyMetrics
            ?? BodyMetrics(weightKg: nil, heightCm: nil, sex: .unspecified, age: nil)
    }

    /// Pull raw Health values into every field the user hasn't manually pinned.
    func refreshFromHealth() async {
        guard let body = try? await health.bodyMetrics(), let profile = try? store.profile() else { return }
        if !profile.isHeightManual, let h = body.heightCm { profile.heightCm = h }
        if !profile.isWeightManual, let w = body.weightKg { profile.weightKg = w }
        if !profile.isBirthManual, let b = body.birthDate { profile.birthDate = b }
        if !profile.isSexManual, body.sex != .unspecified { profile.sex = body.sex }
        try? store.save()
    }
}
```

- [ ] **Step 4: Register the new file and run tests**

```bash
ruby scripts/xcadd.rb Runner/Core/Profile/ProfileStore.swift Runner
ruby scripts/xcadd.rb RunnerTests/ProfileStoreTests.swift RunnerTests
```
Run: `xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RunnerTests/ProfileStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Runner/Core/Health Runner/Core/Profile RunnerTests/FakeHealthStore.swift RunnerTests/ProfileStoreTests.swift Runner.xcodeproj/project.pbxproj
git commit -m "feat: ProfileStore — Health body metrics with manual override"
```

---

### Task 5: Thread calories into the recompute path

Wire `CalorieEngine` + `ProfileStore` into `SyncCoordinator` so `WorkoutRec.calories` is persisted and `DayLedger` derived fields are filled on every sync. Expose the metrics provider from `AppModel`.

**Files:**
- Modify: `Runner/Core/Store/SyncCoordinator.swift`
- Modify: `Runner/App/AppModel.swift`
- Test: `RunnerTests/SyncCoordinatorTests.swift` (add a case)

**Interfaces:**
- Consumes: `CalorieEngine`, `WorkoutEnergyInput`, `BodyMetrics` (Task 2); `DayDerived`, `upsert(_:derived:)`, `upsertWorkout(... calories:)` (Task 3); `ProfileStore.currentMetrics()` (Task 4).
- Produces: `SyncCoordinator.init(health:store:currentGoal:metricsProvider:)` (new `metricsProvider: @escaping () -> BodyMetrics`); `AppModel.profile: ProfileStore`.

- [ ] **Step 1: Write the failing test**

Add to `RunnerTests/SyncCoordinatorTests.swift`:

```swift
@Test @MainActor func syncFillsDerivedCalorieFields() async throws {
    let store = try DataStore(inMemory: true)
    let health = FakeHealthStore()
    let today = Calendar.current.startOfDay(for: .now)
    health.stepsByDay = [today: 10000]
    health.cannedWorkouts = [ExternalWorkout(id: UUID(), type: .run, start: today.addingTimeInterval(3600),
                                             end: today.addingTimeInterval(5400), movingSeconds: 1800,
                                             distanceMeters: 5000, isFromThisApp: false)]
    let sync = SyncCoordinator(health: health, store: store, currentGoal: { 100 },
                               metricsProvider: { BodyMetrics(weightKg: 70, heightCm: 180, sex: .male, age: 30) })
    await sync.syncNow()

    let row = try store.ledger(on: today)
    #expect((row?.activeCalories ?? 0) > 300)         // run + everyday steps
    #expect(row?.distanceMeters == 5000)
    #expect(row?.activeSeconds == 1800)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RunnerTests/SyncCoordinatorTests`
Expected: FAIL — `metricsProvider:` parameter doesn't exist; derived fields are zero.

- [ ] **Step 3: Implement**

In `Runner/Core/Store/SyncCoordinator.swift`:

Add the stored provider and extend `init`:

```swift
    private let metricsProvider: () -> BodyMetrics

    init(health: HealthStoring, store: DataStore, currentGoal: @escaping () -> Int,
         metricsProvider: @escaping () -> BodyMetrics) {
        self.health = health
        self.store = store
        self.currentGoal = currentGoal
        self.metricsProvider = metricsProvider
    }
```

In `saveRecorded`, compute and persist workout calories. After `let id = UUID()` and before the first `upsertWorkout`, add:

```swift
        let metrics = metricsProvider()
        let kcal = metrics.weightKg.map {
            CalorieEngine.workoutCalories(type: workout.type, distanceMeters: workout.distanceMeters,
                                          movingSeconds: workout.movingSeconds, weightKg: $0)
        } ?? 0
```

Pass `calories: kcal` into both `upsertWorkout(...)` calls in `saveRecorded`, and into the two `upsertWorkout` calls in `retryPendingSaves` and the external-cache loop of `performSync` (compute `kcal` there the same way from each workout's fields; for external workouts use `w.movingSeconds`/`w.distanceMeters`, for pending recs use `rec.movingSeconds`/`rec.distanceMeters`).

In `performSync`, build a per-day energy map alongside `workoutsByDay`. Collect `WorkoutEnergyInput` per day. Change the accumulation that appends `WorkoutSummary` so it also records energy inputs. Add before the `days` loop:

```swift
            let metrics = metricsProvider()
            var energyByDay: [Date: [WorkoutEnergyInput]] = [:]
            for w in hkWorkouts {
                let day = cal.startOfDay(for: w.start)
                energyByDay[day, default: []].append(
                    WorkoutEnergyInput(type: w.type, distanceMeters: w.distanceMeters, movingSeconds: w.movingSeconds))
            }
            for rec in try store.pendingSync() {
                let day = cal.startOfDay(for: rec.start)
                energyByDay[day, default: []].append(
                    WorkoutEnergyInput(type: rec.type, distanceMeters: rec.distanceMeters, movingSeconds: rec.movingSeconds))
            }
```

After building `days` and before `LedgerBuilder.build`, compute derived values:

```swift
            var derived: [Date: DayDerived] = [:]
            for day in days {
                let inputs = energyByDay[day.date] ?? []
                let kcal = CalorieEngine.dayCalories(steps: day.steps, workouts: inputs, metrics: metrics)?.total ?? 0
                let meters = inputs.reduce(0.0) { $0 + $1.distanceMeters }
                let seconds = inputs.reduce(0.0) { $0 + $1.movingSeconds }
                derived[day.date] = DayDerived(activeCalories: kcal, distanceMeters: meters, activeSeconds: seconds)
            }
```

Change the final upsert to pass derived data:

```swift
            try store.upsert(ledgers, derived: derived)
```

In `Runner/App/AppModel.swift`:

Add a `let profile: ProfileStore` property. In `init`, construct it and pass `metricsProvider` to the `SyncCoordinator`:

```swift
        self.profile = ProfileStore(store: store, health: health)
        self.sync = SyncCoordinator(health: health, store: store,
                                    currentGoal: { Self.storedGoal() },
                                    metricsProvider: { [profile] in profile.currentMetrics() })
```

(Move `self.profile = ...` above the `self.sync = ...` line so the capture is valid; `profile` is a `let` so capturing it directly avoids a `self` cycle.)

In `onLaunch()`, refresh Health-backed metrics before the first sync — add right after the authorization block:

```swift
        await profile.refreshFromHealth()
```

And in `onForeground()`, add `await profile.refreshFromHealth()` before `await sync.syncNow()`.

- [ ] **Step 4: Run tests to verify pass**

Run: `xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RunnerTests/SyncCoordinatorTests`
Expected: PASS. Then the full suite (existing `AppModelTests` construct `SyncCoordinator`/`AppModel` — update any direct `SyncCoordinator(...)` call in tests to pass `metricsProvider: { BodyMetrics(weightKg: nil, heightCm: nil, sex: .unspecified, age: nil) }`):
`xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Runner/Core/Store/SyncCoordinator.swift Runner/App/AppModel.swift RunnerTests
git commit -m "feat: compute and persist calories in the recompute path"
```

---

### Task 6: Profile screen

A screen to view/edit body metrics, reached from Settings. Manual edits set the `isManual` flag; a "Use Apple Health" control clears it.

**Files:**
- Create: `Runner/Features/Profile/ProfileView.swift`
- Modify: `Runner/Features/Settings/SettingsView.swift` (add a navigation row)

**Interfaces:**
- Consumes: `AppModel.profile` (Task 5), `UserProfile` (Task 3), `Color.r*` tokens, `BodySex`.
- Produces: `struct ProfileView: View`.

- [ ] **Step 1: Create the view**

Create `Runner/Features/Profile/ProfileView.swift`:

```swift
import SwiftUI

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var heightText = ""
    @State private var weightText = ""
    @State private var birthDate = Date()
    @State private var hasBirthDate = false
    @State private var sex: BodySex = .unspecified

    var body: some View {
        List {
            Section {
                Text(String(localized: "Your height, weight, age and sex power the calorie estimates. Values come from Apple Health; edit any of them to override."))
                    .font(.caption)
                    .foregroundStyle(Color.rTextSecondary)
            }

            Section(String(localized: "Body")) {
                metricField(String(localized: "Height (cm)"), text: $heightText)
                metricField(String(localized: "Weight (kg)"), text: $weightText)
                Toggle(String(localized: "Set date of birth"), isOn: $hasBirthDate)
                if hasBirthDate {
                    DatePicker(String(localized: "Date of birth"), selection: $birthDate,
                               in: ...Date(), displayComponents: .date)
                }
                Picker(String(localized: "Sex"), selection: $sex) {
                    Text(String(localized: "Not set")).tag(BodySex.unspecified)
                    Text(String(localized: "Male")).tag(BodySex.male)
                    Text(String(localized: "Female")).tag(BodySex.female)
                }
            }

            Section {
                Button(String(localized: "Reset to Apple Health")) { resetToHealth() }
                    .foregroundStyle(Color.rTeal)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.rBackground)
        .navigationTitle(String(localized: "Profile"))
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
        .onDisappear(perform: save)
    }

    private func metricField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .foregroundStyle(Color.rLime)
        }
    }

    private func load() {
        guard let row = try? model.profile.row() else { return }
        heightText = row.heightCm.map { String(Int($0.rounded())) } ?? ""
        weightText = row.weightKg.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? ""
        if let b = row.birthDate { birthDate = b; hasBirthDate = true }
        sex = row.sex
    }

    private func save() {
        guard let row = try? model.profile.row() else { return }
        let newHeight = Double(heightText.replacingOccurrences(of: ",", with: "."))
        if newHeight != row.heightCm { row.heightCm = newHeight; row.isHeightManual = newHeight != nil }
        let newWeight = Double(weightText.replacingOccurrences(of: ",", with: "."))
        if newWeight != row.weightKg { row.weightKg = newWeight; row.isWeightManual = newWeight != nil }
        let newBirth = hasBirthDate ? birthDate : nil
        if newBirth != row.birthDate { row.birthDate = newBirth; row.isBirthManual = newBirth != nil }
        if sex != row.sex { row.sex = sex; row.isSexManual = sex != .unspecified }
        try? model.store.save()
        Task { await model.sync.syncNow() }
    }

    private func resetToHealth() {
        guard let row = try? model.profile.row() else { return }
        row.isHeightManual = false; row.isWeightManual = false
        row.isBirthManual = false; row.isSexManual = false
        try? model.store.save()
        Task {
            await model.profile.refreshFromHealth()
            await model.sync.syncNow()
            load()
        }
    }
}
```

- [ ] **Step 2: Add the Settings entry point**

In `Runner/Features/Settings/SettingsView.swift`, add a new section above the "Daily goal" section (inside the `List`):

```swift
                Section {
                    NavigationLink {
                        ProfileView()
                    } label: {
                        Label(String(localized: "Profile & body metrics"), systemImage: "person.text.rectangle")
                    }
                }
```

- [ ] **Step 3: Register and build**

```bash
ruby scripts/xcadd.rb Runner/Features/Profile/ProfileView.swift Runner
```
Run: `xcodebuild build -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual verification**

Launch in the simulator (`open -a Simulator`, then run from Xcode or `xcodebuild ... -destination ... build && xcrun simctl install/launch`). Settings → Profile & body metrics: fields load; type a weight, back out, reopen Settings → the value persists; "Reset to Apple Health" clears the manual value.

- [ ] **Step 5: Commit**

```bash
git add Runner/Features/Profile Runner/Features/Settings/SettingsView.swift Runner.xcodeproj/project.pbxproj
git commit -m "feat: Profile screen with Health + manual body metrics"
```

---

### Task 7: Today screen additions — calories, stat strip, 7-day trend

Add the calorie card, a compact stat strip, and a points/calories sparkline below the existing (unchanged) points content.

**Files:**
- Modify: `Runner/Features/Today/TodayView.swift`

**Interfaces:**
- Consumes: `DayLedger.activeCalories/.distanceMeters/.activeSeconds` (Task 3), `CalorieEngine`/`WorkoutEnergyInput` (Task 2), `AppModel.profile` (Task 5), `Format`, `Color.r*`, Swift Charts.
- Produces: no new public types (private view builders inside `TodayView`).

- [ ] **Step 1: Add calories, stat strip, and trend to the body**

In `Runner/Features/Today/TodayView.swift`, add `import Charts` at the top. Insert three new views into the `body`'s `VStack` immediately after `breakdown` and before the `if !latestRoute.isEmpty` block:

```swift
                statStrip
                if model.profile.currentMetrics().weightKg != nil {
                    caloriesCard
                } else {
                    addWeightCard
                }
                trendCard
```

Add these computed properties/methods to `TodayView`:

```swift
    private var todayEnergyInputs: [WorkoutEnergyInput] {
        todayWorkouts.map { WorkoutEnergyInput(type: $0.type, distanceMeters: $0.distanceMeters,
                                               movingSeconds: $0.movingSeconds) }
    }

    private var statStrip: some View {
        HStack(spacing: 10) {
            statTile("🔥", (today?.activeCalories ?? 0) > 0
                     ? "\(Int((today?.activeCalories ?? 0).rounded()))"
                     : "—", String(localized: "kcal"))
            statTile("📏", Format.km(today?.distanceMeters ?? 0), String(localized: "today"))
            statTile("⏱️", Format.duration(today?.activeSeconds ?? 0), String(localized: "active"))
        }
    }

    private func statTile(_ emoji: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 3) {
            Text(emoji).font(.system(size: 18))
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text(unit.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1)
                .foregroundStyle(Color.rTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.rSurface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.rBorder, lineWidth: 1))
    }

    private var caloriesCard: some View {
        let breakdown = CalorieEngine.dayCalories(steps: today?.steps ?? 0,
                                                  workouts: todayEnergyInputs,
                                                  metrics: model.profile.currentMetrics())
        return SurfaceCard {
            VStack(spacing: 0) {
                HStack {
                    Text("🔥 \(String(localized: "Calories burned"))").font(.system(size: 14))
                    Spacer()
                    Text("\(Int((breakdown?.total ?? 0).rounded())) \(String(localized: "kcal"))")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rOrange)
                }
                .padding(.vertical, 10)
                Divider().overlay(Color.rBorder)
                calorieRow(String(localized: "Everyday steps"),
                           Int((breakdown?.everydayKcal ?? 0).rounded()))
                ForEach(Array(todayWorkouts.enumerated()), id: \.element.id) { index, workout in
                    Divider().overlay(Color.rBorder)
                    calorieRow("\(workout.type.emoji) \(workout.type.localizedName) · \(Format.km(workout.distanceMeters))",
                               Int((breakdown?.workoutKcal[safe: index] ?? 0).rounded()))
                }
                Text(String(localized: "Estimated from your body metrics.")).font(.system(size: 11))
                    .foregroundStyle(Color.rTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        }
    }

    private func calorieRow(_ label: String, _ kcal: Int) -> some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(.white)
            Spacer()
            Text("\(kcal) \(String(localized: "kcal"))")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rOrange)
        }
        .padding(.vertical, 10)
    }

    private var addWeightCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(String(localized: "Add your weight to see calories"), systemImage: "scalemass")
                    .font(.subheadline).foregroundStyle(.white)
                Text(String(localized: "Open Settings → Profile to add your weight, or allow Runner to read it from Apple Health."))
                    .font(.caption).foregroundStyle(Color.rTextSecondary)
            }
        }
    }
```

Add the trend card with a points/calories toggle. Add `@State private var trendMode = 0` to `TodayView`, then:

```swift
    private var last7: [DayLedger] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: .now))!
        return ledgers.filter { $0.date >= start }.sorted { $0.date < $1.date }
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MicroLabel(text: String(localized: "Last 7 days"))
                Spacer()
                Picker("", selection: $trendMode) {
                    Text(String(localized: "Points")).tag(0)
                    Text(String(localized: "Calories")).tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            Chart(last7, id: \.date) { day in
                BarMark(x: .value("Day", day.date, unit: .day),
                        y: .value("Value", trendMode == 0 ? Double(day.totalPoints) : day.activeCalories))
                    .foregroundStyle(trendMode == 0 ? Color.rLime : Color.rOrange)
                    .cornerRadius(3)
                if trendMode == 0 {
                    RuleMark(y: .value("Goal", model.dailyGoal))
                        .foregroundStyle(Color.rOrange.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .frame(height: 120)
            .chartYAxis { AxisMarks(position: .trailing) }
        }
    }
```

Add a safe-subscript helper at the bottom of the file (outside the struct):

```swift
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual verification**

Run in the simulator. Today shows: unchanged points block first, then the stat strip (kcal / km / active), the calories card (or the "add your weight" card if no weight), and the 7-day trend with a working Points/Calories toggle. Set a weight in Profile → calories appear.

- [ ] **Step 4: Commit**

```bash
git add Runner/Features/Today/TodayView.swift
git commit -m "feat: Today — calories card, stat strip, 7-day trend"
```

---

### Task 8: Day Detail screen

Tapping a heatmap cell or a chart bar in History opens a full breakdown for that day.

**Files:**
- Create: `Runner/Features/History/DayDetailView.swift`
- Modify: `Runner/Features/History/HeatmapView.swift` (make cells tappable)
- Modify: `Runner/Features/History/HistoryView.swift` (present Day Detail; pass workouts)

**Interfaces:**
- Consumes: `DayLedger`, `WorkoutRec`, `CalorieEngine`, `Format`, `WorkoutDetailView`, `Color.r*`.
- Produces: `struct DayDetailView: View` (`init(date: Date)`); `HeatmapView` gains `onSelect: (Date) -> Void`.

- [ ] **Step 1: Create DayDetailView**

Create `Runner/Features/History/DayDetailView.swift`:

```swift
import SwiftUI
import SwiftData

struct DayDetailView: View {
    @Environment(AppModel.self) private var model
    let date: Date
    @Query private var ledgers: [DayLedger]
    @Query private var workouts: [WorkoutRec]

    init(date: Date) {
        self.date = date
        let cal = Calendar.current
        let lo = cal.startOfDay(for: date)
        let hi = cal.date(byAdding: .day, value: 1, to: lo)!
        _ledgers = Query(filter: #Predicate { $0.date == lo })
        _workouts = Query(filter: #Predicate { $0.start >= lo && $0.start < hi },
                          sort: \WorkoutRec.start, order: .forward)
    }

    private var day: DayLedger? { ledgers.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                pointsCard
                totalsCard
                workoutsList
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 18)
        }
        .background(Color.rBackground)
        .navigationTitle(date.formatted(.dateTime.weekday(.abbreviated).day().month()))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack {
            Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Spacer()
            if day?.isGold == true {
                Text(String(localized: "GOLD")).font(.system(size: 11, weight: .black)).tracking(1.5)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.rLime.opacity(0.15)))
                    .overlay(Capsule().stroke(Color.rLime, lineWidth: 1))
                    .foregroundStyle(Color.rLime)
            }
        }
        .padding(.top, 8)
    }

    private var pointsCard: some View {
        SurfaceCard {
            VStack(spacing: 8) {
                detailRow(String(localized: "Total points"), "\(day?.totalPoints ?? 0)", .rLime)
                detailRow(String(localized: "From steps (\((day?.steps ?? 0).formatted()))"), "\(day?.stepPoints ?? 0)", .white)
                detailRow(String(localized: "From workouts"), "\(day?.workoutPoints ?? 0)", .white)
                if let m = day?.multiplier, m > 1 {
                    detailRow("🔥 \(String(localized: "Streak bonus"))",
                              "×\(m.formatted(.number.precision(.fractionLength(2))))", .rOrange)
                }
                detailRow(String(localized: "Goal that day"), "\(day?.goalAtThatTime ?? 0)", .rTextSecondary)
            }
        }
    }

    private var totalsCard: some View {
        SurfaceCard {
            VStack(spacing: 8) {
                detailRow("🔥 \(String(localized: "Calories burned"))",
                          (day?.activeCalories ?? 0) > 0 ? "\(Int((day?.activeCalories ?? 0).rounded())) \(String(localized: "kcal"))" : "—",
                          .rOrange)
                detailRow("📏 \(String(localized: "Distance"))", Format.km(day?.distanceMeters ?? 0), .white)
                detailRow("⏱️ \(String(localized: "Active time"))", Format.duration(day?.activeSeconds ?? 0), .white)
            }
        }
    }

    @ViewBuilder private var workoutsList: some View {
        if !workouts.isEmpty {
            MicroLabel(text: String(localized: "Workouts"))
            ForEach(workouts) { workout in
                NavigationLink { WorkoutDetailView(workout: workout) } label: {
                    SurfaceCard {
                        HStack {
                            Text(workout.type.emoji).font(.system(size: 20))
                            Text("\(workout.type.localizedName) · \(Format.km(workout.distanceMeters))")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            Spacer()
                            Text("+\(workout.points)").font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(workout.type.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String, _ accent: Color) -> some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(.white)
            Spacer()
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(accent)
        }
    }
}
```

- [ ] **Step 2: Make heatmap cells tappable**

In `Runner/Features/History/HeatmapView.swift`, add `let onSelect: (Date) -> Void` to the struct, and wrap the filled cell in a `Button`. Replace the `if let snapshot {` branch's rectangle with:

```swift
        if let snapshot {
            Button { onSelect(snapshot.date) } label: {
                RoundedRectangle(cornerRadius: 3)
                    .fill(snapshot.points > 0
                          ? Color.rLime.opacity(HistoryMath.intensity(points: snapshot.points, goal: goal))
                          : Color.rSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(snapshot.isGold ? Color.rLime : Color.rBorder,
                                    lineWidth: snapshot.isGold ? 1.5 : 0.5)
                    )
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        } else {
```

- [ ] **Step 3: Wire navigation in HistoryView**

In `Runner/Features/History/HistoryView.swift`, add navigation state and destination. Add `@State private var selectedDate: Date?` to the struct. Pass `onSelect:` to the `HeatmapView`:

```swift
                        HeatmapView(weeks: HistoryMath.heatmapWeeks(days: snapshots,
                                                                    today: .now,
                                                                    weekCount: 13,
                                                                    calendar: .current),
                                    goal: model.dailyGoal,
                                    onSelect: { selectedDate = $0 })
```

Make chart bars tappable too — add a `.chartOverlay` gesture to the `Chart` in `chartSection` that maps the tapped x-position to a date and sets `selectedDate`:

```swift
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            if let date: Date = proxy.value(atX: location.x - geo.frame(in: .local).minX) {
                                selectedDate = Calendar.current.startOfDay(for: date)
                            }
                        }
                }
            }
```

Add a `.navigationDestination` on the `ScrollView` (inside the `NavigationStack`):

```swift
            .navigationDestination(item: $selectedDate) { date in
                DayDetailView(date: date)
            }
```

(Requires `Date` to be `Identifiable` for `navigationDestination(item:)`; add at file scope: `extension Date: @retroactive Identifiable { public var id: TimeInterval { timeIntervalSince1970 } }`.)

- [ ] **Step 4: Register and build**

```bash
ruby scripts/xcadd.rb Runner/Features/History/DayDetailView.swift Runner
```
Run: `xcodebuild build -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manual verification**

Run in the simulator. History → tap a heatmap cell → Day Detail opens with points, calories, distance, active time, and that day's workouts; tapping a workout opens the existing detail. Tapping a chart bar opens the same.

- [ ] **Step 6: Commit**

```bash
git add Runner/Features/History Runner.xcodeproj/project.pbxproj
git commit -m "feat: Day Detail screen from History heatmap and charts"
```

---

### Task 9: Localization, About-calories, and first-run profile prompt

Translate the new strings, add a points-style calories explainer to Settings, and prompt once to review the profile on first v1.1 launch.

**Files:**
- Modify: `Runner/Resources/Localizable.xcstrings`
- Modify: `Runner/Features/Settings/SettingsView.swift`
- Modify: `Runner/Features/Today/TodayView.swift`
- Modify: `Runner/App/AppModel.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `AppModel.showProfilePrompt: Bool` (drives a one-time alert).

- [ ] **Step 1: Add French translations**

Open `Runner/Resources/Localizable.xcstrings` in Xcode (or edit the JSON directly) and add French (`fr`) translations for every new `String(localized:)` key introduced in Tasks 6–8. Required keys and their French values (add each as a `"<key>" : { "localizations": { "fr": { "stringUnit": { "state": "translated", "value": "<fr>" } } } }` entry):

| English key | French |
|---|---|
| Calories burned | Calories brûlées |
| kcal | kcal |
| Estimated from your body metrics. | Estimé à partir de vos mesures corporelles. |
| Everyday steps | Pas quotidiens |
| Add your weight to see calories | Ajoutez votre poids pour voir les calories |
| Open Settings → Profile to add your weight, or allow Runner to read it from Apple Health. | Ouvrez Réglages → Profil pour ajouter votre poids, ou autorisez Runner à le lire depuis Santé. |
| Last 7 days | 7 derniers jours |
| Points | Points |
| Calories | Calories |
| today | aujourd’hui |
| active | actif |
| Profile & body metrics | Profil et mesures |
| Profile | Profil |
| Body | Corps |
| Height (cm) | Taille (cm) |
| Weight (kg) | Poids (kg) |
| Set date of birth | Définir la date de naissance |
| Date of birth | Date de naissance |
| Sex | Sexe |
| Not set | Non défini |
| Male | Homme |
| Female | Femme |
| Reset to Apple Health | Réinitialiser depuis Santé |
| Your height, weight, age and sex power the calorie estimates. Values come from Apple Health; edit any of them to override. | Votre taille, poids, âge et sexe alimentent l’estimation des calories. Les valeurs proviennent de Santé ; modifiez-les pour les remplacer. |
| Distance | Distance |
| Active time | Temps actif |
| Goal that day | Objectif du jour |
| From steps (%@) | À partir des pas (%@) |
| From workouts | À partir des séances |
| Total points | Points totaux |
| GOLD | OR |
| Workouts | Séances |
| How calories work | Le calcul des calories |
| Calories are estimated from your weight, the activity type, and how fast and long you moved — no heart-rate sensor needed. | Les calories sont estimées à partir de votre poids, du type d’activité et de la vitesse et durée de l’effort — sans capteur de fréquence cardiaque. |
| Review your profile | Vérifiez votre profil |
| Runner now estimates calories from your body metrics. Take a moment to check them. | Runner estime désormais les calories à partir de vos mesures corporelles. Prenez un instant pour les vérifier. |
| Open Profile | Ouvrir le profil |
| Later | Plus tard |

- [ ] **Step 2: Add the "How calories work" section to Settings**

In `SettingsView.swift`, add after the "How points work" section:

```swift
                Section(String(localized: "How calories work")) {
                    Text(String(localized: "Calories are estimated from your weight, the activity type, and how fast and long you moved — no heart-rate sensor needed."))
                        .font(.subheadline)
                        .foregroundStyle(Color.rTextSecondary)
                }
```

Also bump the version row value from `"1.0"` to `"1.1"`.

- [ ] **Step 3: One-time profile prompt on first v1.1 launch**

In `Runner/App/AppModel.swift`, add:

```swift
    static let profilePromptKey = "didShowProfilePrompt_v1_1"
    var showProfilePrompt = false
```

At the end of `onLaunch()`:

```swift
        if !UserDefaults.standard.bool(forKey: Self.profilePromptKey) {
            showProfilePrompt = true
            UserDefaults.standard.set(true, forKey: Self.profilePromptKey)
        }
```

In `TodayView.swift`, present it as an alert (add to the outer `ScrollView` modifiers, alongside the existing `.refreshable`). Use a binding to the model:

```swift
        .alert(String(localized: "Review your profile"), isPresented: Bindable(model).showProfilePrompt) {
            Button(String(localized: "Open Profile")) { model.selectedTab = .today; model.showSettings = true }
            Button(String(localized: "Later"), role: .cancel) {}
        } message: {
            Text(String(localized: "Runner now estimates calories from your body metrics. Take a moment to check them."))
        }
```

If `AppModel` has no `showSettings` flag driving the Settings sheet, present the prompt with a single `Button("OK")` dismiss instead (check how `TodayView` currently opens Settings and match it — the prompt only needs to inform; the Settings/Profile path already exists).

- [ ] **Step 4: Build and verify**

Run: `xcodebuild build -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED. Set the simulator language to French (Settings → General → Language) and confirm the new UI is translated. Delete-and-reinstall the app once to confirm the profile prompt shows exactly once.

- [ ] **Step 5: Full test suite**

Run: `xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: PASS (all tests).

- [ ] **Step 6: Commit**

```bash
git add Runner/Resources/Localizable.xcstrings Runner/Features/Settings/SettingsView.swift Runner/Features/Today/TodayView.swift Runner/App/AppModel.swift
git commit -m "feat: French strings, calories explainer, first-run profile prompt"
```

---

## Self-Review

**Spec coverage:**
- §3 Profile & body metrics → Tasks 3 (UserProfile), 4 (resolution), 6 (screen). ✓
- §4 Calorie engine (workout kcal, everyday de-dup, nil-on-no-weight, estimate labeling) → Task 2. ✓
- §5 Today additions (calorie card, stat strip, 7-day trend default points) → Task 7. ✓
- §6 Day Detail from heatmap + charts → Task 8. ✓
- §7 Data model (UserProfile, WorkoutRec.calories, DayLedger derived, cache-safe recompute) → Tasks 3, 5. ✓
- §8 i18n → Task 9. ✓
- §9 Testing (MET, de-dup, nil weight, profile resolution, derived-field sync) → Tasks 2, 4, 5 (+ Day Detail covered by build/manual since it's view aggregation over already-tested engine). ✓
- Empty state "add your weight" → Task 7. ✓
- Points engine untouched → confirmed: no task modifies `PointsEngine`/`LedgerBuilder`. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. The one conditional instruction (Task 9 Step 3 Settings-flag fallback) gives an explicit alternative rather than deferring.

**Type consistency:** `BodyMetrics`/`BodySex`/`WorkoutEnergyInput`/`CalorieBreakdown`/`DayDerived`/`HealthBody` are defined once (Tasks 2–4) and consumed with matching signatures downstream. `dayCalories(steps:workouts:metrics:)`, `workoutCalories(type:distanceMeters:movingSeconds:weightKg:)`, `upsert(_:derived:)`, `upsertWorkout(... calories:)`, `SyncCoordinator.init(... metricsProvider:)`, `ProfileStore.currentMetrics()/refreshFromHealth()/row()` are used identically wherever referenced.
