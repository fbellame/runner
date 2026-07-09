# Runner v1.4 — Trust Real Health Data — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** For imported workouts, prefer HealthKit's own metrics over the app's estimates — real calories (`activeEnergyBurned`), a per-ride + lifetime CO₂-avoided stat (Bixi metadata, computed fallback), and a distance-reading audit.

**Architecture:** New pure `CO2Estimator` and `Co2Metadata` helpers (Foundation-only, unit-tested). `HealthStore.workouts()` reads energy + CO₂ metadata into an enriched `ExternalWorkout`; `SyncCoordinator` picks real-over-estimate and freezes the result into `WorkoutRec` via migration-safe inline-default columns. New values surface in `WorkoutDetailView` tiles and a lifetime CO₂ total in `HistoryView`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, HealthKit, Swift Testing (`import Testing`, `@Test`, `#expect`), XcodeGen.

## Global Constraints

- Swift Testing only (`import Testing` / `@Test` / `#expect`) — never XCTest.
- New SwiftData `@Model` columns MUST have inline defaults (e.g. `= false`, `= 0`) so an existing store lightweight-migrates. Mirror the existing `distanceEstimated` / `calories` pattern.
- All new user-facing strings use `String(localized:)` and MUST get a French translation in `Runner/Resources/Localizable.xcstrings`.
- Pure modules stay Foundation-only and decoupled from SwiftUI/SwiftData/HealthKit.
- CO₂ avoided is **bike-only** for the computed fallback; `CO2Estimator.carGramsPerKm = 192.0`.
- Build/test target: `xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test`, all green before every commit that touches app code.
- Run `xcodegen generate` after adding any NEW source file (so it is registered in the project) before building.
- Final version: `MARKETING_VERSION` 1.4 / `CURRENT_PROJECT_VERSION` 6 in `project.yml`.

---

### Task 1: `CO2Estimator` pure module

**Files:**
- Create: `Runner/Core/Health/CO2Estimator.swift`
- Test: `RunnerTests/CO2EstimatorTests.swift`

**Interfaces:**
- Produces: `enum CO2Estimator { static let carGramsPerKm: Double; static func avoidedGrams(type: ActivityType, distanceMeters: Double) -> Double }`

- [ ] **Step 1: Write the failing test**

Create `RunnerTests/CO2EstimatorTests.swift`:

```swift
import Testing
@testable import Runner

struct CO2EstimatorTests {
    @Test func bikeDistanceMapsToCarGramsAvoided() {
        // 5 km by bike → 5 × 192 g = 960 g avoided.
        let grams = CO2Estimator.avoidedGrams(type: .bike, distanceMeters: 5000)
        #expect(abs(grams - 960.0) < 0.001)
    }

    @Test func nonBikeTypesAvoidNothing() {
        #expect(CO2Estimator.avoidedGrams(type: .run, distanceMeters: 5000) == 0)
        #expect(CO2Estimator.avoidedGrams(type: .walk, distanceMeters: 5000) == 0)
    }

    @Test func nonPositiveDistanceAvoidsNothing() {
        #expect(CO2Estimator.avoidedGrams(type: .bike, distanceMeters: 0) == 0)
        #expect(CO2Estimator.avoidedGrams(type: .bike, distanceMeters: -100) == 0)
    }

    @Test func factorIsTheDocumentedAverageCar() {
        #expect(CO2Estimator.carGramsPerKm == 192.0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | grep -i "CO2Estimator"`
Expected: FAIL — `cannot find 'CO2Estimator' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Runner/Core/Health/CO2Estimator.swift`:

```swift
import Foundation

/// Grams of car tailpipe CO₂ avoided by covering distance under human power.
/// Bike-only: this is the Bixi "green impact" framing. Foundation-only, pure.
enum CO2Estimator {
    /// Average passenger-car tailpipe CO₂, grams per km. Named for easy tuning.
    static let carGramsPerKm = 192.0

    static func avoidedGrams(type: ActivityType, distanceMeters: Double) -> Double {
        guard type == .bike, distanceMeters > 0 else { return 0 }
        return (distanceMeters / 1000.0) * carGramsPerKm
    }
}
```

- [ ] **Step 4: Register the new file and run the tests**

Run: `xcodegen generate && xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | tail -5`
Expected: build succeeds; CO2EstimatorTests pass.

- [ ] **Step 5: Commit**

```bash
git add Runner/Core/Health/CO2Estimator.swift RunnerTests/CO2EstimatorTests.swift Runner.xcodeproj
git commit -m "feat: CO2Estimator — bike distance to car CO2 avoided"
```

---

### Task 2: Migration-safe model + transport fields

**Files:**
- Modify: `Runner/Core/Store/Models.swift:52-90` (`WorkoutRec`)
- Modify: `Runner/Core/Health/HealthStoring.swift:4-25` (`ExternalWorkout`)
- Modify: `Runner/Core/Store/DataStore.swift:108-145` (`upsertWorkout`)
- Modify: `RunnerTests/FakeHealthStore.swift:60-66` (add new `ExternalWorkout` args)
- Test: `RunnerTests/DataStoreTests.swift` (add cases)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `WorkoutRec` new stored vars: `caloriesFromHealth: Bool = false`, `co2SavedGrams: Double = 0`, `co2FromHealth: Bool = false`; init gains the three params with those defaults (appended after `calories`).
  - `ExternalWorkout` new lets: `activeEnergyKcal: Double?`, `co2SavedGrams: Double?`; init gains both params defaulting to `nil` (appended before `isFromThisApp`).
  - `DataStore.upsertWorkout(...)` gains params `caloriesFromHealth: Bool = false, co2SavedGrams: Double = 0, co2FromHealth: Bool = false` (appended after `calories`).

- [ ] **Step 1: Write the failing test**

Add to `RunnerTests/DataStoreTests.swift` (inside the existing `struct DataStoreTests`):

```swift
    @Test func upsertPersistsHealthCalorieAndCo2Flags() throws {
        let store = try DataStore(inMemory: true)
        let id = UUID()
        let rec = try store.upsertWorkout(id: id, type: .bike, start: .now, end: .now,
                                          movingSeconds: 600, distanceMeters: 2500,
                                          points: 5, routeData: nil, splitSeconds: [],
                                          source: "external", hkSynced: true,
                                          calories: 88, caloriesFromHealth: true,
                                          co2SavedGrams: 480, co2FromHealth: true)
        #expect(rec.caloriesFromHealth == true)
        #expect(rec.co2SavedGrams == 480)
        #expect(rec.co2FromHealth == true)
    }

    @Test func co2FieldsRefreshOnResyncButCaloriesStayFrozen() throws {
        let store = try DataStore(inMemory: true)
        let id = UUID()
        _ = try store.upsertWorkout(id: id, type: .bike, start: .now, end: .now,
                                    movingSeconds: 600, distanceMeters: 2500,
                                    points: 5, routeData: nil, splitSeconds: [],
                                    source: "external", hkSynced: true,
                                    calories: 88, caloriesFromHealth: true,
                                    co2SavedGrams: 480, co2FromHealth: false)
        // Re-sync same id with a different CO₂ figure; calories are frozen, CO₂ refreshes.
        let rec = try store.upsertWorkout(id: id, type: .bike, start: .now, end: .now,
                                          movingSeconds: 600, distanceMeters: 2500,
                                          points: 5, routeData: nil, splitSeconds: [],
                                          source: "external", hkSynced: true,
                                          calories: 200, caloriesFromHealth: false,
                                          co2SavedGrams: 500, co2FromHealth: true)
        #expect(rec.calories == 88)             // frozen (was non-zero)
        #expect(rec.caloriesFromHealth == true) // frozen alongside calories
        #expect(rec.co2SavedGrams == 500)       // refreshed
        #expect(rec.co2FromHealth == true)      // refreshed
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | grep -iE "caloriesFromHealth|co2SavedGrams|error:"`
Expected: FAIL — `extra arguments 'caloriesFromHealth', 'co2SavedGrams', 'co2FromHealth'`.

- [ ] **Step 3a: Extend `WorkoutRec`**

In `Runner/Core/Store/Models.swift`, add stored vars after `var calories: Double = 0` (line 68):

```swift
    // Real-vs-estimated provenance + CO₂ avoided. Inline defaults keep an existing
    // store lightweight-migratable, mirroring `distanceEstimated` / `calories`.
    var caloriesFromHealth: Bool = false
    var co2SavedGrams: Double = 0
    var co2FromHealth: Bool = false
```

Update the initializer signature (line 72-75) — append params before the body:

```swift
    init(id: UUID, typeRaw: String, start: Date, end: Date, movingSeconds: Double,
         distanceMeters: Double, distanceEstimated: Bool = false, points: Int,
         routeData: Data?, splitSeconds: [Double],
         source: String, hkSynced: Bool, calories: Double = 0,
         caloriesFromHealth: Bool = false, co2SavedGrams: Double = 0,
         co2FromHealth: Bool = false) {
```

And add to the init body after `self.calories = calories` (line 88):

```swift
        self.caloriesFromHealth = caloriesFromHealth
        self.co2SavedGrams = co2SavedGrams
        self.co2FromHealth = co2FromHealth
```

- [ ] **Step 3b: Extend `ExternalWorkout`**

In `Runner/Core/Health/HealthStoring.swift`, add lets after `let distanceEstimated: Bool` (line 11):

```swift
    let activeEnergyKcal: Double?
    let co2SavedGrams: Double?
```

Update its init (line 14-24) to accept both (defaulting nil), appended before `isFromThisApp`:

```swift
    init(id: UUID, type: ActivityType, start: Date, end: Date, movingSeconds: Double,
         distanceMeters: Double, distanceEstimated: Bool = false,
         activeEnergyKcal: Double? = nil, co2SavedGrams: Double? = nil,
         isFromThisApp: Bool) {
        self.id = id
        self.type = type
        self.start = start
        self.end = end
        self.movingSeconds = movingSeconds
        self.distanceMeters = distanceMeters
        self.distanceEstimated = distanceEstimated
        self.activeEnergyKcal = activeEnergyKcal
        self.co2SavedGrams = co2SavedGrams
        self.isFromThisApp = isFromThisApp
    }
```

- [ ] **Step 3c: Extend `DataStore.upsertWorkout`**

In `Runner/Core/Store/DataStore.swift`, change the signature (line 109-113):

```swift
    func upsertWorkout(id: UUID, type: ActivityType, start: Date, end: Date,
                       movingSeconds: Double, distanceMeters: Double,
                       distanceEstimated: Bool = false, points: Int, routeData: Data?,
                       splitSeconds: [Double], source: String, hkSynced: Bool,
                       calories: Double = 0, caloriesFromHealth: Bool = false,
                       co2SavedGrams: Double = 0, co2FromHealth: Bool = false) throws -> WorkoutRec {
```

In the UPDATE branch, replace the freeze block (line 133) with:

```swift
            // Freeze calories (and their provenance) once computed; CO₂ is
            // deterministic from distance/metadata, so refresh it every sync.
            if existing.calories == 0 {
                existing.calories = calories
                existing.caloriesFromHealth = caloriesFromHealth
            }
            existing.co2SavedGrams = co2SavedGrams
            existing.co2FromHealth = co2FromHealth
```

In the INSERT branch, pass the new args to the `WorkoutRec(...)` initializer (line 136-140):

```swift
            rec = WorkoutRec(id: id, typeRaw: type.rawValue, start: start, end: end,
                             movingSeconds: movingSeconds, distanceMeters: distanceMeters,
                             distanceEstimated: distanceEstimated,
                             points: points, routeData: routeData, splitSeconds: splitSeconds,
                             source: source, hkSynced: hkSynced, calories: calories,
                             caloriesFromHealth: caloriesFromHealth,
                             co2SavedGrams: co2SavedGrams, co2FromHealth: co2FromHealth)
```

- [ ] **Step 3d: Fix `FakeHealthStore` construction**

In `RunnerTests/FakeHealthStore.swift`, the `saveWorkout` `ExternalWorkout(...)` (line 60-66) still compiles (new params default nil). No change required — verify it builds. If the compiler flags the trailing `isFromThisApp:` argument order, keep `distanceEstimated: false,` then `isFromThisApp: true` (defaults cover the two new params).

- [ ] **Step 4: Run tests**

Run: `xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | tail -5`
Expected: build succeeds; the two new DataStore tests pass; all prior tests still green.

- [ ] **Step 5: Commit**

```bash
git add Runner/Core/Store/Models.swift Runner/Core/Health/HealthStoring.swift Runner/Core/Store/DataStore.swift RunnerTests/DataStoreTests.swift RunnerTests/FakeHealthStore.swift
git commit -m "feat: migration-safe caloriesFromHealth + CO2 columns on WorkoutRec"
```

---

### Task 3: `CalorieEngine.dayCalories` prefers real per-workout energy

**Files:**
- Modify: `Runner/Core/CalorieEngine/CalorieEngine.swift:14-18` (`WorkoutEnergyInput`), `:98-118` (`dayCalories`)
- Test: `RunnerTests/CalorieEngineTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `WorkoutEnergyInput` gains `let realKcal: Double?` and an explicit init `init(type:distanceMeters:movingSeconds:realKcal: Double? = nil)`. `dayCalories` uses `realKcal` when non-nil, else the MET computation.

- [ ] **Step 1: Write the failing test**

Add to `RunnerTests/CalorieEngineTests.swift`:

```swift
    // A workout carrying a real Health kcal value uses it verbatim, not the MET math.
    @Test func dayCaloriesPrefersRealKcalWhenPresent() {
        let metrics = BodyMetrics(weightKg: 70, heightCm: 175, sex: .male, age: 30)
        let real = WorkoutEnergyInput(type: .bike, distanceMeters: 5000,
                                      movingSeconds: 1200, realKcal: 42)
        let breakdown = CalorieEngine.dayCalories(steps: 0, workouts: [real], metrics: metrics)
        #expect(breakdown?.workoutKcal == [42])
    }

    @Test func dayCaloriesFallsBackToMETWhenNoRealKcal() {
        let metrics = BodyMetrics(weightKg: 70, heightCm: 175, sex: .male, age: 30)
        let est = WorkoutEnergyInput(type: .run, distanceMeters: 5000, movingSeconds: 1800)
        let breakdown = CalorieEngine.dayCalories(steps: 0, workouts: [est], metrics: metrics)
        let met = CalorieEngine.workoutCalories(type: .run, distanceMeters: 5000,
                                                movingSeconds: 1800, weightKg: 70)
        #expect(breakdown?.workoutKcal.first.map { abs($0 - met) < 0.001 } == true)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | grep -iE "realKcal|error:"`
Expected: FAIL — `extra argument 'realKcal'`.

- [ ] **Step 3: Implement**

In `Runner/Core/CalorieEngine/CalorieEngine.swift`, replace `WorkoutEnergyInput` (line 14-18):

```swift
struct WorkoutEnergyInput: Equatable, Sendable {
    let type: ActivityType
    let distanceMeters: Double
    let movingSeconds: Double
    /// Real active energy from Health, when the source recorded it; else nil → MET estimate.
    let realKcal: Double?

    init(type: ActivityType, distanceMeters: Double, movingSeconds: Double,
         realKcal: Double? = nil) {
        self.type = type
        self.distanceMeters = distanceMeters
        self.movingSeconds = movingSeconds
        self.realKcal = realKcal
    }
}
```

In `dayCalories`, replace the `workoutKcal` map (line 102-105):

```swift
        let workoutKcal = workouts.map {
            $0.realKcal ?? workoutCalories(type: $0.type, distanceMeters: $0.distanceMeters,
                                           movingSeconds: $0.movingSeconds, weightKg: weightKg)
        }
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | tail -5`
Expected: build succeeds; both new tests pass; existing CalorieEngine tests still green (`realKcal` defaults nil).

- [ ] **Step 5: Commit**

```bash
git add Runner/Core/CalorieEngine/CalorieEngine.swift RunnerTests/CalorieEngineTests.swift
git commit -m "feat: dayCalories prefers real Health kcal over MET estimate"
```

---

### Task 4: `Co2Metadata` parser + `HealthStore` reads energy & CO₂

**Files:**
- Create: `Runner/Core/Health/Co2Metadata.swift`
- Modify: `Runner/Core/Health/HealthStore.swift:11-25` (add read type), `:192-207` (enrich `workouts()` mapping)
- Test: `RunnerTests/Co2MetadataTests.swift`

**Interfaces:**
- Consumes: `ExternalWorkout` fields from Task 2.
- Produces: `enum Co2Metadata { static func grams(from metadata: [String: Any]?) -> Double? }` — finds the first key whose lowercased name contains `"co2"` or `"carbon"`, parses an `NSNumber`/numeric-`String` value, and returns grams (values below `kgThreshold = 100` are treated as kilograms → ×1000). Returns nil when no key matches or the value is non-numeric.

- [ ] **Step 1: Write the failing test**

Create `RunnerTests/Co2MetadataTests.swift`:

```swift
import Testing
@testable import Runner

struct Co2MetadataTests {
    @Test func readsGramsFromNumberInGrams() {
        // A large value is already grams.
        #expect(Co2Metadata.grams(from: ["CO2Emission": 480]) == 480)
    }

    @Test func treatsSmallValueAsKilograms() {
        // Bixi-style small value → kilograms → grams.
        let grams = Co2Metadata.grams(from: ["co2_saved_kg": 0.48])
        #expect(grams != nil && abs(grams! - 480) < 0.001)
    }

    @Test func parsesNumericString() {
        #expect(Co2Metadata.grams(from: ["carbonAvoided": "480"]) == 480)
    }

    @Test func caseInsensitiveKeyMatch() {
        #expect(Co2Metadata.grams(from: ["HKMetadataCo2Grams": 250]) == 250)
    }

    @Test func nilWhenNoCo2Key() {
        #expect(Co2Metadata.grams(from: ["HKElevationAscended": 12]) == nil)
        #expect(Co2Metadata.grams(from: nil) == nil)
    }

    @Test func nilWhenValueNotNumeric() {
        #expect(Co2Metadata.grams(from: ["co2": "n/a"]) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | grep -iE "Co2Metadata|error:"`
Expected: FAIL — `cannot find 'Co2Metadata' in scope`.

- [ ] **Step 3a: Implement the parser**

Create `Runner/Core/Health/Co2Metadata.swift`:

```swift
import Foundation

/// Best-effort reader for a workout's CO₂-avoided metadata (Bixi writes a custom
/// key; HealthKit has no standard CO₂ type). Heuristic + unit-guess; callers fall
/// back to `CO2Estimator` when this returns nil, so a changed Bixi schema degrades
/// gracefully instead of breaking. Pure — testable with a plain dictionary.
enum Co2Metadata {
    /// Below this the value is assumed to be kilograms rather than grams.
    static let kgThreshold = 100.0

    static func grams(from metadata: [String: Any]?) -> Double? {
        guard let metadata else { return nil }
        let match = metadata.first { key, _ in
            let k = key.lowercased()
            return k.contains("co2") || k.contains("carbon")
        }
        guard let value = match?.value else { return nil }

        let number: Double?
        switch value {
        case let n as NSNumber: number = n.doubleValue
        case let s as String: number = Double(s)
        default: number = nil
        }
        guard let number, number > 0 else { return nil }
        return number < kgThreshold ? number * 1000.0 : number
    }
}
```

- [ ] **Step 3b: Read the new types in `HealthStore`**

In `Runner/Core/Health/HealthStore.swift`, add a property after `private let distanceCycling` (line 12):

```swift
    private let activeEnergyType = HKQuantityType(.activeEnergyBurned)
```

Add it to `readTypes` (line 21-25), inserting `activeEnergyType` into the set:

```swift
    private var readTypes: Set<HKObjectType> {
        [stepType, workoutType, routeType, distanceWalkRun, distanceCycling,
         activeEnergyType, heightType, bodyMassType,
         HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex)]
    }
```

In `workouts(daysBack:)`, replace the `return samples.compactMap { ... }` body (line 192-206) so it also reads energy + CO₂:

```swift
        return samples.compactMap { sample in
            guard let workout = sample as? HKWorkout,
                  let type = HealthMappers.activityType(from: workout.workoutActivityType) else { return nil }
            let realMeters = workoutDistanceMeters(workout, type: type)
            let estimatedMeters = realMeters == 0
                ? WorkoutEstimation.estimatedMeters(type: type, movingSeconds: workout.duration)
                : nil
            let meters = estimatedMeters ?? realMeters
            let energyKcal = workoutEnergyKcal(workout)
            let co2Grams = Co2Metadata.grams(from: workout.metadata)
            return ExternalWorkout(id: workout.uuid, type: type, start: workout.startDate,
                                   end: workout.endDate,
                                   movingSeconds: workout.duration,
                                   distanceMeters: meters,
                                   distanceEstimated: estimatedMeters != nil,
                                   activeEnergyKcal: energyKcal,
                                   co2SavedGrams: co2Grams,
                                   isFromThisApp: workout.sourceRevision.source.bundleIdentifier == bundleID)
        }
```

Add a private helper next to `workoutDistanceMeters` (after line 223):

```swift
    /// Real active energy (kcal) for an imported workout, or nil when the source
    /// recorded none. Prefer the per-type statistic; fall back to the aggregate.
    private func workoutEnergyKcal(_ workout: HKWorkout) -> Double? {
        let unit = HKUnit.kilocalorie()
        if let kcal = workout.statistics(for: activeEnergyType)?.sumQuantity()?
            .doubleValue(for: unit), kcal > 0 {
            return kcal
        }
        if let kcal = workout.totalEnergyBurned?.doubleValue(for: unit), kcal > 0 {
            return kcal
        }
        return nil
    }
```

- [ ] **Step 4: Register the new file and run tests**

Run: `xcodegen generate && xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | tail -5`
Expected: build succeeds; Co2MetadataTests pass; all prior tests green.

- [ ] **Step 5: Commit**

```bash
git add Runner/Core/Health/Co2Metadata.swift Runner/Core/Health/HealthStore.swift RunnerTests/Co2MetadataTests.swift Runner.xcodeproj
git commit -m "feat: read activeEnergyBurned + CO2 metadata from HealthKit workouts"
```

---

### Task 5: `SyncCoordinator` prefer-real wiring

**Files:**
- Modify: `Runner/Core/Store/SyncCoordinator.swift:117-145` (external upsert + energy inputs)
- Test: `RunnerTests/SyncCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ExternalWorkout.activeEnergyKcal` / `.co2SavedGrams` (Task 2/4), `DataStore.upsertWorkout` new params (Task 2), `WorkoutEnergyInput.realKcal` (Task 3), `CO2Estimator.avoidedGrams` (Task 1).
- Produces: external `WorkoutRec` rows whose `calories`/`caloriesFromHealth`/`co2SavedGrams`/`co2FromHealth` reflect real-over-estimate; day energy inputs carrying `realKcal`.

- [ ] **Step 1: Write the failing test**

Add to `RunnerTests/SyncCoordinatorTests.swift` (inside the existing suite; follow the file's existing setup for building a `SyncCoordinator` with `FakeHealthStore` + in-memory `DataStore` — reuse the same helper the other tests use):

```swift
    @Test func externalWorkoutUsesRealHealthCaloriesAndCo2() async throws {
        let health = FakeHealthStore()
        let store = try DataStore(inMemory: true)
        let now = Date()
        health.earliestHistoryDateStub = now
        health.cannedWorkouts = [
            ExternalWorkout(id: UUID(), type: .bike, start: now, end: now,
                            movingSeconds: 1200, distanceMeters: 5000,
                            activeEnergyKcal: 130, co2SavedGrams: 900,
                            isFromThisApp: false)
        ]
        let sync = SyncCoordinator(health: health, store: store,
                                   currentGoal: { 100 },
                                   metricsProvider: { BodyMetrics(weightKg: 70, heightCm: 175, sex: .male, age: 30) })
        await sync.syncNow()

        let rec = try #require(try store.allWorkouts().first)
        #expect(rec.calories == 130)
        #expect(rec.caloriesFromHealth == true)
        #expect(rec.co2SavedGrams == 900)
        #expect(rec.co2FromHealth == true)
    }

    @Test func externalWorkoutFallsBackToEstimatesWhenHealthHasNone() async throws {
        let health = FakeHealthStore()
        let store = try DataStore(inMemory: true)
        let now = Date()
        health.earliestHistoryDateStub = now
        health.cannedWorkouts = [
            ExternalWorkout(id: UUID(), type: .bike, start: now, end: now,
                            movingSeconds: 1200, distanceMeters: 5000,
                            activeEnergyKcal: nil, co2SavedGrams: nil,
                            isFromThisApp: false)
        ]
        let sync = SyncCoordinator(health: health, store: store,
                                   currentGoal: { 100 },
                                   metricsProvider: { BodyMetrics(weightKg: 70, heightCm: 175, sex: .male, age: 30) })
        await sync.syncNow()

        let rec = try #require(try store.allWorkouts().first)
        #expect(rec.caloriesFromHealth == false)
        #expect(rec.co2FromHealth == false)
        // 5 km bike → CO2Estimator computed value.
        #expect(abs(rec.co2SavedGrams - CO2Estimator.avoidedGrams(type: .bike, distanceMeters: 5000)) < 0.001)
    }
```

> NOTE: if the existing tests use a shared factory (e.g. `makeCoordinator(...)`), call it instead of the inline `SyncCoordinator(...)` above to stay DRY. Read the top of `SyncCoordinatorTests.swift` first.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | grep -iE "caloriesFromHealth|co2FromHealth|error:"`
Expected: FAIL — assertions on `caloriesFromHealth`/`co2FromHealth` fail (fields not yet populated by the coordinator).

- [ ] **Step 3: Implement**

In `Runner/Core/Store/SyncCoordinator.swift`, replace the external-cache loop (line 118-129):

```swift
            // Cache external workouts for the UI (ours are already cached at record time).
            for w in hkWorkouts where !w.isFromThisApp {
                let estKcal = workoutCalories(type: w.type, distanceMeters: w.distanceMeters,
                                              movingSeconds: w.movingSeconds, metrics: metrics)
                let kcal = w.activeEnergyKcal ?? estKcal
                let co2 = w.co2SavedGrams
                    ?? CO2Estimator.avoidedGrams(type: w.type, distanceMeters: w.distanceMeters)
                try store.upsertWorkout(id: w.id, type: w.type, start: w.start,
                                        end: w.end, movingSeconds: w.movingSeconds,
                                        distanceMeters: w.distanceMeters,
                                        distanceEstimated: w.distanceEstimated,
                                        points: PointsEngine.workoutPoints(type: w.type,
                                                                           distanceMeters: w.distanceMeters),
                                        routeData: nil, splitSeconds: [],
                                        source: "external", hkSynced: true,
                                        calories: kcal,
                                        caloriesFromHealth: w.activeEnergyKcal != nil,
                                        co2SavedGrams: co2,
                                        co2FromHealth: w.co2SavedGrams != nil)
            }
```

In the day-energy loop, replace the `hkWorkouts` append (line 134-138) so real kcal flows into the day total:

```swift
            for w in hkWorkouts {
                let day = cal.startOfDay(for: w.start)
                energyByDay[day, default: []].append(
                    WorkoutEnergyInput(type: w.type, distanceMeters: w.distanceMeters,
                                       movingSeconds: w.movingSeconds, realKcal: w.activeEnergyKcal))
            }
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | tail -5`
Expected: build succeeds; both new SyncCoordinator tests pass; all prior tests green.

- [ ] **Step 5: Commit**

```bash
git add Runner/Core/Store/SyncCoordinator.swift RunnerTests/SyncCoordinatorTests.swift
git commit -m "feat: SyncCoordinator prefers real Health calories + CO2 for imports"
```

---

### Task 6: Surface Calories + CO₂ tiles in `WorkoutDetailView`

**Files:**
- Modify: `Runner/DesignSystem/Format.swift` (add `kcal`, `co2`)
- Modify: `Runner/Features/History/WorkoutDetailView.swift:28-35` (add a second stat row)
- Test: `RunnerTests/FormatTests.swift`

**Interfaces:**
- Consumes: `WorkoutRec.calories/caloriesFromHealth/co2SavedGrams` (Task 2).
- Produces: `Format.kcal(_ value: Double, estimated: Bool = false) -> String`, `Format.co2(grams: Double) -> String`.

- [ ] **Step 1: Write the failing test**

Add to `RunnerTests/FormatTests.swift`:

```swift
    @Test func kcalFormatsWithEstimateMarker() {
        #expect(Format.kcal(130) == "130 kcal")
        #expect(Format.kcal(130, estimated: true) == "~130 kcal")
    }

    @Test func co2FormatsAsKilograms() {
        #expect(Format.co2(grams: 900) == "0.9 kg")
        #expect(Format.co2(grams: 1500) == "1.5 kg")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | grep -iE "Format.kcal|Format.co2|error:"`
Expected: FAIL — `type 'Format' has no member 'kcal'`.

- [ ] **Step 3a: Add Format helpers**

In `Runner/DesignSystem/Format.swift`, add inside `enum Format` (after `km`, line 26):

```swift
    static func kcal(_ value: Double, estimated: Bool = false) -> String {
        let prefix = estimated ? "~" : ""
        return prefix + "\(Int(value.rounded())) kcal"
    }

    static func co2(grams: Double) -> String {
        let kg = grams / 1000.0
        return kg.formatted(.number.precision(.fractionLength(1))) + " kg"
    }
```

- [ ] **Step 3b: Add the tiles**

In `Runner/Features/History/WorkoutDetailView.swift`, immediately after the existing `HStack(spacing: 10) { ... }` stat row (closes at line 35), add:

```swift
                if workout.calories > 0 || workout.co2SavedGrams > 0 {
                    HStack(spacing: 10) {
                        if workout.calories > 0 {
                            StatTile(label: String(localized: "Calories"),
                                     value: Format.kcal(workout.calories,
                                                        estimated: !workout.caloriesFromHealth),
                                     accent: .rOrange)
                        }
                        if workout.co2SavedGrams > 0 {
                            StatTile(label: String(localized: "CO₂ saved"),
                                     value: Format.co2(grams: workout.co2SavedGrams),
                                     accent: .rLime)
                        }
                    }
                }
```

> `StatTile(label:value:accent:)` is the existing component used one line above; match its call shape.

- [ ] **Step 4: Run tests**

Run: `xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | tail -5`
Expected: build succeeds; FormatTests pass; app compiles with the new tiles.

- [ ] **Step 5: Commit**

```bash
git add Runner/DesignSystem/Format.swift Runner/Features/History/WorkoutDetailView.swift RunnerTests/FormatTests.swift
git commit -m "feat: Calories + CO2 tiles on Workout Detail"
```

---

### Task 7: Lifetime CO₂ total in History

**Files:**
- Modify: `Runner/Features/History/ActivityStats.swift:3-29` (`ActivityWorkoutSummary`), `:43-50` (`LifetimeTotals`), `:122-139` (`lifetimeTotals`)
- Modify: `Runner/Features/History/HistoryView.swift:404-417` (`init(workout:)`), `:154-172` (`lifetimeTotalsSection`)
- Test: `RunnerTests/ActivityStatsTests.swift`

**Interfaces:**
- Consumes: `WorkoutRec.co2SavedGrams` (Task 2), `Format.co2` (Task 6).
- Produces: `ActivityWorkoutSummary.co2SavedGrams: Double` (init param default `0`); `LifetimeTotals.co2SavedGrams: Double`; `lifetimeTotals` sums it.

- [ ] **Step 1: Write the failing test**

Add to `RunnerTests/ActivityStatsTests.swift`:

```swift
    @Test func lifetimeTotalsSumCo2Saved() {
        let summaries = [
            ActivityWorkoutSummary(id: UUID(), type: .bike, date: .now, distanceMeters: 5000,
                                   movingSeconds: 1200, points: 5, calories: 100,
                                   splitSeconds: [], hasRoute: false, co2SavedGrams: 900),
            ActivityWorkoutSummary(id: UUID(), type: .bike, date: .now, distanceMeters: 3000,
                                   movingSeconds: 800, points: 3, calories: 60,
                                   splitSeconds: [], hasRoute: false, co2SavedGrams: 576),
        ]
        let totals = ActivityStats.lifetimeTotals(summaries)
        #expect(abs(totals.co2SavedGrams - 1476) < 0.001)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | grep -iE "co2SavedGrams|error:"`
Expected: FAIL — `extra argument 'co2SavedGrams'` / `has no member 'co2SavedGrams'`.

- [ ] **Step 3a: Extend `ActivityWorkoutSummary`**

In `ActivityStats.swift`, add `let co2SavedGrams: Double` after `let hasRoute: Bool` (line 13), add it to the init signature (default `0`, appended last) and body:

```swift
    let hasRoute: Bool
    let co2SavedGrams: Double

    init(id: UUID, type: ActivityType, date: Date, distanceMeters: Double,
         distanceEstimated: Bool = false, movingSeconds: Double, points: Int,
         calories: Double, splitSeconds: [Double], hasRoute: Bool,
         co2SavedGrams: Double = 0) {
        self.id = id
        self.type = type
        self.date = date
        self.distanceMeters = distanceMeters
        self.distanceEstimated = distanceEstimated
        self.movingSeconds = movingSeconds
        self.points = points
        self.calories = calories
        self.splitSeconds = splitSeconds
        self.hasRoute = hasRoute
        self.co2SavedGrams = co2SavedGrams
    }
```

- [ ] **Step 3b: Extend `LifetimeTotals` + its builder**

Add `let co2SavedGrams: Double` after `let routesPainted: Int` (line 48). In `lifetimeTotals(...)` (line 133-138), add the summed argument:

```swift
        return LifetimeTotals(distanceMeters: summaries.reduce(0) { $0 + $1.distanceMeters },
                              movingSeconds: summaries.reduce(0) { $0 + $1.movingSeconds },
                              calories: summaries.reduce(0) { $0 + $1.calories },
                              workouts: summaries.count,
                              routesPainted: summaries.filter(\.hasRoute).count,
                              co2SavedGrams: summaries.reduce(0) { $0 + $1.co2SavedGrams },
                              perType: perType)
```

> `perType` stays the last argument — insert `co2SavedGrams:` before it, and update the `LifetimeTotals` struct field order to match (place `co2SavedGrams` before `perType`).

- [ ] **Step 3c: Thread it through `init(workout:)`**

In `HistoryView.swift` (line 405-415), add the field to the `self.init(...)`:

```swift
    init(workout: WorkoutRec) {
        self.init(id: workout.id,
                  type: workout.type,
                  date: workout.start,
                  distanceMeters: workout.distanceMeters,
                  distanceEstimated: workout.distanceEstimated,
                  movingSeconds: workout.movingSeconds,
                  points: workout.points,
                  calories: workout.calories,
                  splitSeconds: workout.splitSeconds,
                  hasRoute: workout.routeData != nil,
                  co2SavedGrams: workout.co2SavedGrams)
    }
```

- [ ] **Step 3d: Surface the tile**

In `HistoryView.swift` `lifetimeTotalsSection` (line 154-172), add a fifth `StatTile` inside the grid (after the Workouts tile), shown only when there is CO₂ to report:

```swift
                if totals.co2SavedGrams > 0 {
                    StatTile(label: String(localized: "CO₂ saved"),
                             value: Format.co2(grams: totals.co2SavedGrams),
                             accent: .rTeal)
                }
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | tail -5`
Expected: build succeeds; the lifetime CO₂ test passes; all prior tests green.

- [ ] **Step 5: Commit**

```bash
git add Runner/Features/History/ActivityStats.swift Runner/Features/History/HistoryView.swift RunnerTests/ActivityStatsTests.swift
git commit -m "feat: lifetime CO2-saved total on History"
```

---

### Task 8: Diagnostics discovery dump (metadata + distance source + energy)

**Files:**
- Modify: `Runner/Core/Health/HealthStore.swift:80-109` (workout scan in `diagnosticsReport`)

**Interfaces:**
- Consumes: existing diagnostics scaffolding.
- Produces: no new public API; richer diagnostics text.

- [ ] **Step 1: Extend the scan**

In `Runner/Core/Health/HealthStore.swift`, inside `diagnosticsReport()`'s workout-scan `do` block, after the per-type tally loop and before `lines.append("Sources: ...")` (around line 106), add a per-sample dump for up to 5 cycling workouts:

```swift
            let cyclingSamples = workouts.filter { $0.workoutActivityType == .cycling }.prefix(5)
            if !cyclingSamples.isEmpty {
                lines.append("Sample cycling workouts (first \(cyclingSamples.count)):")
                for w in cyclingSamples {
                    let type = HealthMappers.activityType(from: w.workoutActivityType) ?? .bike
                    let cyc = w.statistics(for: distanceCycling)?.sumQuantity()?.doubleValue(for: .meter())
                    let wr = w.statistics(for: distanceWalkRun)?.sumQuantity()?.doubleValue(for: .meter())
                    let agg = w.totalDistance?.doubleValue(for: .meter())
                    let kcal = workoutEnergyKcal(w)
                    let co2 = Co2Metadata.grams(from: w.metadata)
                    let keys = (w.metadata?.keys.sorted()).map { $0.joined(separator: ",") } ?? "none"
                    lines.append("  \(df.string(from: w.startDate)) dur=\(Int(w.duration))s "
                        + "dist[cyc=\(cyc.map { Int($0) } ?? -1),wr=\(wr.map { Int($0) } ?? -1),"
                        + "agg=\(agg.map { Int($0) } ?? -1)] used=\(Int(workoutDistanceMeters(w, type: type))) "
                        + "kcal=\(kcal.map { Int($0) } ?? -1) co2g=\(co2.map { Int($0) } ?? -1)")
                    lines.append("    metaKeys: \(keys)")
                }
            }
```

- [ ] **Step 2: Build (no new unit test — this is device-read diagnostics)**

Run: `xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | tail -5`
Expected: build succeeds; all tests green (this change is print-only).

- [ ] **Step 3: Commit**

```bash
git add Runner/Core/Health/HealthStore.swift
git commit -m "feat: diagnostics dump metadata keys, distance source, energy for cycling workouts"
```

---

### Task 9: French strings, version bump, device verification

**Files:**
- Modify: `Runner/Resources/Localizable.xcstrings`
- Modify: `project.yml` (`info.properties`)

**Interfaces:** none.

- [ ] **Step 1: Add French translations**

For each NEW `String(localized:)` key introduced by this plan, add a French translation in `Runner/Resources/Localizable.xcstrings`. Keys and their French values:
- `"Calories"` → `"Calories"`
- `"CO₂ saved"` → `"CO₂ économisé"`

Follow the existing xcstrings JSON structure (locate an existing key like `"Distance"`, copy its `"fr"` entry shape). If `"Calories"` already exists in the catalog (it is used in `HistoryView` lifetime totals), do not duplicate it — only add `"CO₂ saved"`.

- [ ] **Step 2: Bump the version**

In `project.yml`, under `info.properties`, set:

```yaml
    CFBundleShortVersionString: "1.4"
    CFBundleVersion: "6"
```

(Match the existing keys — the plist uses these, not the build settings.)

- [ ] **Step 3: Regenerate, build, and test**

Run: `xcodegen generate && xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test 2>&1 | tail -8`
Expected: build succeeds; ALL tests green (prior ~142 plus the new CO2Estimator / Co2Metadata / DataStore / CalorieEngine / SyncCoordinator / Format / ActivityStats cases).

- [ ] **Step 4: Commit**

```bash
git add Runner/Resources/Localizable.xcstrings project.yml
git commit -m "chore: French strings for calories/CO2, bump to 1.4 (build 6)"
```

- [ ] **Step 5: Deploy and verify on device**

Run: `./scripts/deploy.sh` (cable-connected iPhone, unlocked).
Then on the device, verify:
1. **Settings → HealthKit diagnostics** — read the new cycling-workout dump. Confirm Bixi's CO₂ metadata key/unit is caught (co2g ≠ -1) and distances read non-zero when Health shows them. If co2g is always -1 but a metadata key clearly holds CO₂, note the exact key and, if needed, tighten the heuristic in `Co2Metadata` (a follow-up commit).
2. **A Bixi ride's Workout Detail** — Calories tile shows a real value (no `~`) when Health has energy; CO₂ saved tile shows kg.
3. **History → Lifetime totals** — the "CO₂ saved" tile shows a plausible lifetime kg.

- [ ] **Step 6: Update memory + PR**

Append a note to the v1.4 line in memory (`v1.2-history-trends-epic.md` follow-on or a new `v1.4` memory) recording the discovered Bixi CO₂ key/unit and whether real calories showed up. Open/refresh the PR for `runner-v1.4-real-health-metrics`.

---

## Self-Review

**Spec coverage:**
- Real calories (read `activeEnergyBurned`, prefer over MET, label) → Tasks 2,3,4,5,6. ✓
- CO₂ avoided (read Bixi metadata, compute fallback, per-ride + lifetime) → Tasks 1,4,5,6,7. ✓
- Distance audit (diagnostics, estimate only when 0) → Task 8 (+ no logic change, confirmed via dump). ✓
- Migration-safe model fields → Task 2 (inline defaults). ✓
- New pure `CO2Estimator` + tests → Task 1. ✓
- French strings + version 1.4/6 + build/test/deploy → Task 9. ✓
- Non-goals (no HR/elevation, no Green Impact screen, bike-only CO₂) respected — nothing in the tasks adds them. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output. ✓

**Type consistency:** `co2SavedGrams` is `Double` grams everywhere; `Double?` only as the transport (`ExternalWorkout`) and metadata-reader return; `activeEnergyKcal: Double?`; `WorkoutEnergyInput.realKcal: Double?`; `caloriesFromHealth`/`co2FromHealth: Bool`. `CO2Estimator.avoidedGrams(type:distanceMeters:)` and `Co2Metadata.grams(from:)` signatures match all call sites. `Format.kcal`/`Format.co2` match their tile uses. ✓
