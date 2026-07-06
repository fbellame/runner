# Runner iPhone App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Runner, a dark neon iPhone fitness app that turns daily steps and GPS-recorded run/walk/bike workouts into daily points with streaks, route maps, history charts — with Apple Health as the permanent system of record.

**Architecture:** Pure-logic cores (PointsEngine, LedgerBuilder, LocationFilter, AutoPause) with zero iOS dependencies, wrapped by three gateways (HealthStore for HealthKit, WorkoutRecorder for CoreLocation, DataStore for SwiftData cache), orchestrated by a SyncCoordinator, presented by four SwiftUI feature screens. HealthKit is the source of truth; SwiftData is a rebuildable cache.

**Tech Stack:** Swift 6 / SwiftUI, iOS 18.0 minimum, HealthKit, CoreLocation, MapKit for SwiftUI, Swift Charts, SwiftData, Swift Testing (`import Testing`) for tests, XcodeGen for project generation, Xcode 26.6. No third-party app dependencies.

**Spec:** `docs/superpowers/specs/2026-07-05-runner-fitness-app-design.md` — treat it as the requirements authority.

## Global Constraints

- Bundle ID `com.farid.runner`, app display name **Runner**, deployment target **iOS 18.0**.
- **No third-party app dependencies.** XcodeGen is build tooling only (installed via Homebrew), never linked into the app.
- Points rules, verbatim from spec: steps `floor(steps / 100)` capped at **200 pts/day**; run `round(km × 15)`; walk `round(km × 10)`; bike `round(km × 6)`; streak multiplier `min(1 + 0.05 × n, 1.5)` where n = consecutive gold days **before** today; day total `round((stepPts + Σ workoutPts) × multiplier)`; goal default **100** (range 50–500 step 10); a day is local midnight→midnight.
- GPS rules, verbatim: drop samples with `horizontalAccuracy > 30 m` or age > 10 s; min displacement 3 m; auto-pause run/walk at speed < 0.5 m/s for 10 s, bike < 1.0 m/s for 15 s, resume above threshold for 3 s; checkpoint every 30 s; GPS gap = > 15 s between kept samples → dotted segment, no distance credited for the gap segment.
- Colors, verbatim: background `#0A0B10`, surface `#141824`, border `#232B3D`, lime `#C8FF00`, teal `#3DF5C6` (run), purple `#B48CFF` (bike), orange `#FF7A3D` (streak), secondary text `#8A8F9E`. Dark mode only.
- All user-facing strings in **English (base) + French** via `Localizable.xcstrings` (Task 16 holds the full table; write code with English literals so keys match).
- Metric only (km, min/km). Dates via system locale formatters.
- Free Apple ID signing: `CODE_SIGN_STYLE = Automatic`; simulator builds/tests must not require signing.
- Every simulator command targets the simulator created in Task 1, named exactly **RunnerSim**.
- Commit after every task (steps include the commands). Commit messages end with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

## Environment Prerequisites (verified / created in Task 1)

- macOS with Xcode 26.6 at `/Applications/Xcode.app` (verified present).
- Homebrew available for `xcodegen` install.
- iOS simulator runtime may be **missing** — Task 1 downloads it if needed (multi-GB download; be patient).
- Device deploy (Task 18) needs: Farid's Apple ID added in Xcode ▸ Settings ▸ Accounts (manual, once), iPhone in Developer Mode, cable.

## Task Overview

| # | Task | Deliverable |
|---|------|-------------|
| 1 | Project scaffold | Empty Runner app builds & smoke test passes on RunnerSim |
| 2 | Design system | Theme tokens + reusable components |
| 3 | PointsEngine | Pure scoring rules, fully unit-tested |
| 4 | LedgerBuilder | Streak/gold walk-forward, unit-tested |
| 5 | SwiftData models + DataStore | Persistence cache, in-memory tested |
| 6 | LocationFilter + AutoPauseDetector | Pure GPS logic, unit-tested |
| 7 | CheckpointStore | Crash-safe session persistence |
| 8 | WorkoutRecorder | Recording orchestration w/ synthetic-location tests |
| 9 | HealthStore | HealthKit gateway behind protocol |
| 10 | SyncCoordinator | HK → engine → cache pipeline, tested with fakes |
| 11 | App shell | Tab bar, Settings, permissions UX |
| 12 | Today screen | Points, breakdown, mini-map, celebration |
| 13 | Record screen | Live HUD, slide-to-finish, summary, resume flow |
| 14 | History screen | Heatmap, charts, workout list + detail |
| 15 | Routes screen | All parcours overlay + tap-to-open |
| 16 | Localization | Full EN+FR string catalog |
| 17 | Icon & polish | App icon, launch screen, haptics |
| 18 | Deploy & validate | deploy.sh, device install, success-criteria checklist |

---

### Task 1: Project Scaffold

**Files:**
- Create: `project.yml`
- Create: `Runner/App/RunnerApp.swift`
- Create: `Runner/App/RootTabView.swift` (placeholder version; Task 11 completes it)
- Create: `Runner/Runner.entitlements`
- Create: `Runner/Resources/Assets.xcassets/Contents.json` (+ `LaunchBackground.colorset`, `AccentColor.colorset`)
- Create: `RunnerTests/SmokeTests.swift`
- Test: `RunnerTests/SmokeTests.swift`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a generated `Runner.xcodeproj` (never hand-edited — always regenerate with `xcodegen generate`), scheme `Runner`, simulator `RunnerSim`, and the build/test commands every later task uses verbatim:
  - Build: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' build`
  - Test: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test`

- [ ] **Step 1: Install XcodeGen if missing**

Run: `which xcodegen || brew install xcodegen`
Expected: a path like `/opt/homebrew/bin/xcodegen` (install takes ~1 min if missing).

- [ ] **Step 2: Ensure an iOS simulator runtime exists, create RunnerSim**

```bash
# Is any iOS runtime installed?
xcrun simctl list runtimes | grep -q "iOS" || sudo xcodebuild -downloadPlatform iOS
# Latest installed iOS runtime identifier:
RUNTIME=$(xcrun simctl list runtimes | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS[^ )]*' | tail -1)
# Newest iPhone device type:
DEVTYPE=$(xcrun simctl list devicetypes | grep -o 'com.apple.CoreSimulator.SimDeviceType.iPhone-1[0-9][^ )]*' | tail -1)
# Create deterministic simulator (skip if it already exists):
xcrun simctl list devices | grep -q "RunnerSim" || xcrun simctl create RunnerSim "$DEVTYPE" "$RUNTIME"
xcrun simctl list devices | grep RunnerSim
```

Expected: a line like `RunnerSim (XXXXXXXX-…) (Shutdown)`. If `-downloadPlatform` was needed it can take 15+ min; `sudo` may prompt — if sudo is unavailable in this session, run `xcodebuild -downloadPlatform iOS` without sudo (works on Xcode 26 for the current user) and re-check.

- [ ] **Step 3: Write `project.yml`**

```yaml
name: Runner
options:
  bundleIdPrefix: com.farid
  deploymentTarget:
    iOS: "18.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "6.0"
    IPHONEOS_DEPLOYMENT_TARGET: "18.0"
targets:
  Runner:
    type: application
    platform: iOS
    sources:
      - Runner
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.farid.runner
        PRODUCT_NAME: Runner
        CODE_SIGN_STYLE: Automatic
        CODE_SIGN_ENTITLEMENTS: Runner/Runner.entitlements
        TARGETED_DEVICE_FAMILY: "1"
        INFOPLIST_KEY_UIUserInterfaceStyle: Dark
        SWIFT_STRICT_CONCURRENCY: complete
    info:
      path: Runner/Info.plist
      properties:
        CFBundleDisplayName: Runner
        UILaunchScreen:
          UIColorName: LaunchBackground
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
        NSHealthShareUsageDescription: "Runner reads your daily steps and workouts to compute your daily points."
        NSHealthUpdateUsageDescription: "Runner saves your recorded runs, walks and rides to Apple Health so your data is permanently yours."
        NSLocationWhenInUseUsageDescription: "Runner uses your location to record your route while you run, walk or ride."
        UIBackgroundModes: [location]
        ITSAppUsesNonExemptEncryption: false
  RunnerTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - RunnerTests
    dependencies:
      - target: Runner
    settings:
      base:
        GENERATE_INFOPLIST_FILE: true
        # XcodeGen sets TEST_HOST/BUNDLE_LOADER automatically for unit-test
        # targets that depend on an app target — do not set them by hand.
schemes:
  Runner:
    build:
      targets:
        Runner: all
    test:
      gatherCoverageData: false
      targets:
        - RunnerTests
    run:
      config: Debug
```

- [ ] **Step 4: Write `Runner/Runner.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.healthkit</key>
	<true/>
	<key>com.apple.developer.healthkit.background-delivery</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 5: Write the minimal app**

`Runner/App/RunnerApp.swift`:

```swift
import SwiftUI

@main
struct RunnerApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
                .preferredColorScheme(.dark)
        }
    }
}
```

`Runner/App/RootTabView.swift` (placeholder — Task 11 replaces it):

```swift
import SwiftUI

struct RootTabView: View {
    var body: some View {
        Text("Runner")
            .font(.largeTitle.bold())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}
```

- [ ] **Step 6: Create asset catalog**

`Runner/Resources/Assets.xcassets/Contents.json`:

```json
{ "info": { "author": "xcode", "version": 1 } }
```

`Runner/Resources/Assets.xcassets/LaunchBackground.colorset/Contents.json` (the spec background `#0A0B10` → components below):

```json
{
  "colors": [
    {
      "color": {
        "color-space": "srgb",
        "components": { "red": "0.039", "green": "0.043", "blue": "0.063", "alpha": "1.000" }
      },
      "idiom": "universal"
    }
  ],
  "info": { "author": "xcode", "version": 1 }
}
```

`Runner/Resources/Assets.xcassets/AccentColor.colorset/Contents.json` (lime `#C8FF00`):

```json
{
  "colors": [
    {
      "color": {
        "color-space": "srgb",
        "components": { "red": "0.784", "green": "1.000", "blue": "0.000", "alpha": "1.000" }
      },
      "idiom": "universal"
    }
  ],
  "info": { "author": "xcode", "version": 1 }
}
```

- [ ] **Step 7: Write the smoke test**

`RunnerTests/SmokeTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

struct SmokeTests {
    @Test func testsRunAgainstTheAppHost() {
        // Bundle.main is Runner.app only when TEST_HOST wiring is correct —
        // this catches broken test-target configuration, not app logic.
        #expect(Bundle.main.bundleIdentifier == "com.farid.runner")
    }
}
```

- [ ] **Step 8: Generate project, build, test**

```bash
xcodegen generate
xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' build
xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test
```

Expected: `BUILD SUCCEEDED`, then `TEST SUCCEEDED` with 1 test passing. First build boots the simulator; allow a few minutes.

- [ ] **Step 9: Commit**

```bash
git add project.yml Runner/ RunnerTests/ && git commit -m "feat: scaffold Runner app project (xcodegen, entitlements, smoke test)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

Note: `Runner.xcodeproj` is generated — add it to `.gitignore` in this step (`echo "Runner.xcodeproj/" >> .gitignore && git add .gitignore`). Every task regenerates it with `xcodegen generate` if missing.

---

### Task 2: Design System

**Files:**
- Create: `Runner/DesignSystem/Theme.swift`
- Create: `Runner/DesignSystem/Components.swift`
- Test: `RunnerTests/ThemeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (used by every Feature task):
  - `extension Color { init(hex: UInt32) }` and static tokens `Color.rBackground`, `.rSurface`, `.rBorder`, `.rLime`, `.rTeal`, `.rPurple`, `.rOrange`, `.rTextSecondary`
  - `ActivityType` (`enum ActivityType: String, Codable, CaseIterable, Sendable { case run, walk, bike }`) with `var emoji: String`, `var accent: Color`, `var localizedName: String` — **defined here** so both DesignSystem and Core can use it
  - `struct GlowNumber: View` (`init(value: Int, unitLabel: String)`) — the big glowing points number
  - `struct GoalBar: View` (`init(points: Int, goal: Int)`) — gradient progress bar
  - `struct SurfaceCard<Content: View>: View` (`init(@ViewBuilder content: () -> Content)`) — dark card with border
  - `struct GlowShadow: ViewModifier` (`init(color: Color)`), applied as `.modifier(GlowShadow(color: .rLime))`

- [ ] **Step 1: Write failing test**

`RunnerTests/ThemeTests.swift`:

```swift
import Testing
import SwiftUI
@testable import Runner

struct ThemeTests {
    @Test func hexColorResolvesComponents() {
        let c = UIColor(Color(hex: 0xC8FF00))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(abs(r - 200.0/255.0) < 0.01)
        #expect(abs(g - 1.0) < 0.01)
        #expect(abs(b - 0.0) < 0.01)
        #expect(a == 1.0)
    }

    @Test func activityAccents() {
        #expect(ActivityType.run.emoji == "🏃")
        #expect(ActivityType.walk.emoji == "🚶")
        #expect(ActivityType.bike.emoji == "🚴")
        #expect(ActivityType.allCases.count == 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -20`
Expected: **compile failure** — `Color` has no initializer `init(hex:)`, `ActivityType` not found.

- [ ] **Step 3: Implement Theme**

`Runner/DesignSystem/Theme.swift`:

```swift
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }

    static let rBackground = Color(hex: 0x0A0B10)
    static let rSurface = Color(hex: 0x141824)
    static let rBorder = Color(hex: 0x232B3D)
    static let rLime = Color(hex: 0xC8FF00)
    static let rTeal = Color(hex: 0x3DF5C6)
    static let rPurple = Color(hex: 0xB48CFF)
    static let rOrange = Color(hex: 0xFF7A3D)
    static let rTextSecondary = Color(hex: 0x8A8F9E)
}

enum ActivityType: String, Codable, CaseIterable, Sendable {
    case run, walk, bike

    var emoji: String {
        switch self {
        case .run: "🏃"
        case .walk: "🚶"
        case .bike: "🚴"
        }
    }

    var accent: Color {
        switch self {
        case .run: .rTeal
        case .walk: .rLime
        case .bike: .rPurple
        }
    }

    var localizedName: String {
        switch self {
        case .run: String(localized: "Run")
        case .walk: String(localized: "Walk")
        case .bike: String(localized: "Bike")
        }
    }
}

struct GlowShadow: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.55), radius: 12)
            .shadow(color: color.opacity(0.25), radius: 28)
    }
}
```

- [ ] **Step 4: Implement Components**

`Runner/DesignSystem/Components.swift`:

```swift
import SwiftUI

struct GlowNumber: View {
    let value: Int
    let unitLabel: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(value)")
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .modifier(GlowShadow(color: .rLime))
            Text(unitLabel)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rLime)
        }
    }
}

struct GoalBar: View {
    let points: Int
    let goal: Int

    private var fraction: Double {
        guard goal > 0 else { return 0 }
        return min(Double(points) / Double(goal), 1.0)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0x1B1E27))
                Capsule()
                    .fill(LinearGradient(colors: [.rLime, .rTeal],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geo.size.width * fraction, fraction > 0 ? 8 : 0))
                    .shadow(color: Color.rLime.opacity(0.6), radius: 6)
            }
        }
        .frame(height: 6)
        .animation(.spring(duration: 0.5), value: points)
    }
}

struct SurfaceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.rSurface)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.rBorder, lineWidth: 1))
            )
    }
}

struct MicroLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(2)
            .textCase(.uppercase)
            .foregroundStyle(Color.rTextSecondary)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -5`
Expected: `TEST SUCCEEDED`, 3 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Runner/DesignSystem RunnerTests/ThemeTests.swift
git commit -m "feat: Electric Night design system (theme tokens, glow components)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: PointsEngine

**Files:**
- Create: `Runner/Core/PointsEngine/PointsEngine.swift`
- Test: `RunnerTests/PointsEngineTests.swift`

**Interfaces:**
- Consumes: `ActivityType` from Task 2.
- Produces (exact API relied on by Tasks 4, 8, 10, 12, 13):

```swift
struct WorkoutSummary: Equatable, Sendable {
    let type: ActivityType
    let distanceMeters: Double
}

struct PointsBreakdown: Equatable, Sendable {
    let stepPoints: Int
    let workoutPoints: Int
    let multiplier: Double
    let total: Int
}

enum PointsEngine {
    static let stepDivisor = 100
    static let stepCap = 200
    static func rate(for type: ActivityType) -> Double   // run 15, walk 10, bike 6
    static func stepPoints(steps: Int) -> Int
    static func workoutPoints(type: ActivityType, distanceMeters: Double) -> Int
    static func multiplier(streakBefore: Int) -> Double
    static func breakdown(steps: Int, workouts: [WorkoutSummary], streakBefore: Int) -> PointsBreakdown
    static func livePoints(type: ActivityType, distanceMeters: Double) -> Int  // floor, for the ticking HUD
}
```

- [ ] **Step 1: Write failing tests**

`RunnerTests/PointsEngineTests.swift`:

```swift
import Testing
@testable import Runner

struct PointsEngineTests {
    // Steps: floor(steps/100), cap 200
    @Test(arguments: [
        (0, 0), (99, 0), (100, 1), (8_450, 84), (19_999, 199), (20_000, 200), (55_000, 200),
    ])
    func stepPoints(steps: Int, expected: Int) {
        #expect(PointsEngine.stepPoints(steps: steps) == expected)
    }

    // Workouts: round(km × rate)
    @Test func workoutPointsPerType() {
        #expect(PointsEngine.workoutPoints(type: .run, distanceMeters: 2_100) == 32)   // 2.1×15=31.5 → 32
        #expect(PointsEngine.workoutPoints(type: .walk, distanceMeters: 2_100) == 21)  // 2.1×10=21
        #expect(PointsEngine.workoutPoints(type: .bike, distanceMeters: 10_000) == 60) // 10×6=60
        #expect(PointsEngine.workoutPoints(type: .run, distanceMeters: 0) == 0)
        #expect(PointsEngine.workoutPoints(type: .bike, distanceMeters: 8_249) == 49)  // 8.249×6=49.494 → 49
    }

    // Multiplier: min(1 + 0.05n, 1.5); n = gold days BEFORE today
    @Test(arguments: [
        (0, 1.0), (1, 1.05), (4, 1.2), (9, 1.45), (10, 1.5), (11, 1.5), (400, 1.5),
    ])
    func multiplier(streak: Int, expected: Double) {
        #expect(abs(PointsEngine.multiplier(streakBefore: streak) - expected) < 0.0001)
    }

    // Total: round((stepPts + workoutPts) × multiplier)
    @Test func breakdownComposition() {
        let b = PointsEngine.breakdown(
            steps: 8_450,
            workouts: [WorkoutSummary(type: .run, distanceMeters: 2_100)],
            streakBefore: 4
        )
        #expect(b.stepPoints == 84)
        #expect(b.workoutPoints == 32)
        #expect(abs(b.multiplier - 1.2) < 0.0001)
        #expect(b.total == 139) // (84+32)×1.2 = 139.2 → 139
    }

    @Test func breakdownEmptyDay() {
        let b = PointsEngine.breakdown(steps: 0, workouts: [], streakBefore: 0)
        #expect(b == PointsBreakdown(stepPoints: 0, workoutPoints: 0, multiplier: 1.0, total: 0))
    }

    @Test func breakdownMultipleWorkouts() {
        let b = PointsEngine.breakdown(
            steps: 1_000,
            workouts: [
                WorkoutSummary(type: .run, distanceMeters: 5_000),   // 75
                WorkoutSummary(type: .bike, distanceMeters: 12_000), // 72
            ],
            streakBefore: 0
        )
        #expect(b.workoutPoints == 147)
        #expect(b.total == 157) // (10+147)×1.0
    }

    // Live HUD floors
    @Test func livePointsFloors() {
        #expect(PointsEngine.livePoints(type: .run, distanceMeters: 2_100) == 31)  // floor(31.5)
        #expect(PointsEngine.livePoints(type: .walk, distanceMeters: 999) == 9)    // floor(9.99)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -20`
Expected: compile failure — `PointsEngine` not found.

- [ ] **Step 3: Implement**

`Runner/Core/PointsEngine/PointsEngine.swift`:

```swift
import Foundation

struct WorkoutSummary: Equatable, Sendable {
    let type: ActivityType
    let distanceMeters: Double
}

struct PointsBreakdown: Equatable, Sendable {
    let stepPoints: Int
    let workoutPoints: Int
    let multiplier: Double
    let total: Int
}

enum PointsEngine {
    static let stepDivisor = 100
    static let stepCap = 200
    static let streakBonusPerDay = 0.05
    static let multiplierCap = 1.5

    static func rate(for type: ActivityType) -> Double {
        switch type {
        case .run: 15
        case .walk: 10
        case .bike: 6
        }
    }

    static func stepPoints(steps: Int) -> Int {
        min(steps / stepDivisor, stepCap)
    }

    static func workoutPoints(type: ActivityType, distanceMeters: Double) -> Int {
        Int(((distanceMeters / 1000.0) * rate(for: type)).rounded())
    }

    static func multiplier(streakBefore: Int) -> Double {
        min(1.0 + streakBonusPerDay * Double(streakBefore), multiplierCap)
    }

    static func breakdown(steps: Int, workouts: [WorkoutSummary], streakBefore: Int) -> PointsBreakdown {
        let sp = stepPoints(steps: steps)
        let wp = workouts.reduce(0) { $0 + workoutPoints(type: $1.type, distanceMeters: $1.distanceMeters) }
        let m = multiplier(streakBefore: streakBefore)
        let total = Int((Double(sp + wp) * m).rounded())
        return PointsBreakdown(stepPoints: sp, workoutPoints: wp, multiplier: m, total: total)
    }

    static func livePoints(type: ActivityType, distanceMeters: Double) -> Int {
        Int((distanceMeters / 1000.0) * rate(for: type))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -5`
Expected: `TEST SUCCEEDED` — all PointsEngine tests (20 cases) pass.

- [ ] **Step 5: Commit**

```bash
git add Runner/Core/PointsEngine RunnerTests/PointsEngineTests.swift
git commit -m "feat: points engine — composite scoring rules from spec §4

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: LedgerBuilder

**Files:**
- Create: `Runner/Core/PointsEngine/LedgerBuilder.swift`
- Test: `RunnerTests/LedgerBuilderTests.swift`

**Interfaces:**
- Consumes: `PointsEngine`, `WorkoutSummary`, `PointsBreakdown` (Task 3).
- Produces (relied on by Tasks 5, 10):

```swift
struct DayActivity: Equatable, Sendable {
    let date: Date            // startOfDay, local
    let steps: Int
    let workouts: [WorkoutSummary]
}

struct LedgerDay: Equatable, Sendable {
    let date: Date
    let steps: Int
    let breakdown: PointsBreakdown
    let goal: Int
    let isGold: Bool          // breakdown.total >= goal
    let streakAfter: Int      // consecutive gold days including this one (0 if not gold)
}

enum LedgerBuilder {
    /// days MUST be sorted ascending by date and contain no duplicates.
    /// goalProvider returns the goal in force for a given day (stored goal for
    /// finalized days, current goal otherwise).
    static func build(days: [DayActivity],
                      goalProvider: (Date) -> Int,
                      initialStreak: Int) -> [LedgerDay]
}
```

- [ ] **Step 1: Write failing tests**

`RunnerTests/LedgerBuilderTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

struct LedgerBuilderTests {
    private func day(_ offset: Int, steps: Int, workouts: [WorkoutSummary] = []) -> DayActivity {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000)) // fixed anchor
        return DayActivity(date: cal.date(byAdding: .day, value: offset, to: base)!,
                           steps: steps, workouts: workouts)
    }

    @Test func streakGrowsAndMultiplierLagsOneDay() {
        // 3 days, all 12,000 steps = 120 pts base, goal 100.
        let days = [day(0, steps: 12_000), day(1, steps: 12_000), day(2, steps: 12_000)]
        let out = LedgerBuilder.build(days: days, goalProvider: { _ in 100 }, initialStreak: 0)
        #expect(out.count == 3)
        // Day 0: multiplier ×1.0 (no prior streak), total 120, gold, streakAfter 1
        #expect(out[0].breakdown.multiplier == 1.0)
        #expect(out[0].breakdown.total == 120)
        #expect(out[0].isGold && out[0].streakAfter == 1)
        // Day 1: ×1.05 → 126, streakAfter 2
        #expect(abs(out[1].breakdown.multiplier - 1.05) < 0.0001)
        #expect(out[1].breakdown.total == 126)
        #expect(out[1].streakAfter == 2)
        // Day 2: ×1.10 → 132
        #expect(out[2].breakdown.total == 132)
        #expect(out[2].streakAfter == 3)
    }

    @Test func missedDayResetsStreak() {
        let days = [day(0, steps: 12_000), day(1, steps: 3_000), day(2, steps: 12_000)]
        let out = LedgerBuilder.build(days: days, goalProvider: { _ in 100 }, initialStreak: 5)
        // Day 0 enters with streak 5 → ×1.25, total 150, streakAfter 6
        #expect(abs(out[0].breakdown.multiplier - 1.25) < 0.0001)
        #expect(out[0].streakAfter == 6)
        // Day 1: 30 pts, not gold → streakAfter 0 (multiplier was ×1.3 but total 39 < 100)
        #expect(out[1].isGold == false)
        #expect(out[1].streakAfter == 0)
        // Day 2 enters with streak 0 → ×1.0
        #expect(out[2].breakdown.multiplier == 1.0)
        #expect(out[2].streakAfter == 1)
    }

    @Test func workoutsCountTowardGold() {
        let days = [day(0, steps: 2_000, workouts: [WorkoutSummary(type: .run, distanceMeters: 6_000)])]
        let out = LedgerBuilder.build(days: days, goalProvider: { _ in 100 }, initialStreak: 0)
        // 20 + 90 = 110 → gold
        #expect(out[0].breakdown.total == 110)
        #expect(out[0].isGold)
    }

    @Test func goalProviderPerDay() {
        let days = [day(0, steps: 8_000), day(1, steps: 8_000)]
        let goals: [Int] = [70, 90]
        let out = LedgerBuilder.build(days: days,
                                      goalProvider: { d in
                                          Calendar.current.dateComponents([.day], from: days[0].date, to: d).day == 0 ? goals[0] : goals[1]
                                      },
                                      initialStreak: 0)
        #expect(out[0].goal == 70 && out[0].isGold)     // 80 ≥ 70
        #expect(out[1].goal == 90 && out[1].isGold == false) // 84 (80×1.05=84) < 90
    }

    @Test func emptyInput() {
        #expect(LedgerBuilder.build(days: [], goalProvider: { _ in 100 }, initialStreak: 3).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -20`
Expected: compile failure — `LedgerBuilder` / `DayActivity` not found.

- [ ] **Step 3: Implement**

`Runner/Core/PointsEngine/LedgerBuilder.swift`:

```swift
import Foundation

struct DayActivity: Equatable, Sendable {
    let date: Date
    let steps: Int
    let workouts: [WorkoutSummary]
}

struct LedgerDay: Equatable, Sendable {
    let date: Date
    let steps: Int
    let breakdown: PointsBreakdown
    let goal: Int
    let isGold: Bool
    let streakAfter: Int
}

enum LedgerBuilder {
    static func build(days: [DayActivity],
                      goalProvider: (Date) -> Int,
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
                                 goal: goal, isGold: isGold, streakAfter: streak))
        }
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -5`
Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Runner/Core/PointsEngine/LedgerBuilder.swift RunnerTests/LedgerBuilderTests.swift
git commit -m "feat: ledger builder — streak walk-forward with per-day goals

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 5: SwiftData Models + DataStore

**Files:**
- Create: `Runner/Core/Store/Models.swift`
- Create: `Runner/Core/Store/DataStore.swift`
- Test: `RunnerTests/DataStoreTests.swift`

**Interfaces:**
- Consumes: `LedgerDay` (Task 4), `ActivityType` (Task 2).
- Produces (relied on by Tasks 10, 12, 13, 14, 15):

```swift
@Model final class DayLedger        // fields below
@Model final class WorkoutRec       // fields below

@MainActor final class DataStore {
    let container: ModelContainer
    init(inMemory: Bool = false) throws
    func upsert(_ days: [LedgerDay]) throws
    func ledger(on date: Date) throws -> DayLedger?              // any Date; normalized to startOfDay
    func ledgers(from: Date, through: Date) throws -> [DayLedger] // ascending by date
    func latestLedger(before date: Date) throws -> DayLedger?
    @discardableResult
    func upsertWorkout(id: UUID, type: ActivityType, start: Date, end: Date,
                       movingSeconds: Double, distanceMeters: Double, points: Int,
                       routeData: Data?, splitSeconds: [Double],
                       source: String, hkSynced: Bool) throws -> WorkoutRec
    func workouts(onDay date: Date) throws -> [WorkoutRec]        // ascending by start
    func allWorkouts() throws -> [WorkoutRec]                     // newest first
    func pendingSync() throws -> [WorkoutRec]                     // source=="runner" && !hkSynced
    func goalProvider(currentGoal: Int) -> (Date) -> Int
    // Days BEFORE today: stored goalAtThatTime (else currentGoal).
    // Today and later: ALWAYS currentGoal — spec: "goal edit affects only today forward",
    // so a mid-day goal change must re-score today even though today's ledger already exists.
}
```

Source constants: `"runner"` for workouts recorded by this app, `"external"` for workouts read from HealthKit written by other apps.

- [ ] **Step 1: Write failing tests**

`RunnerTests/DataStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

@MainActor
struct DataStoreTests {
    private func makeStore() throws -> DataStore { try DataStore(inMemory: true) }

    private func ledgerDay(_ offset: Int, total: Int, goal: Int = 100) -> LedgerDay {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: .now))!
        return LedgerDay(date: date, steps: total * 100,
                         breakdown: PointsBreakdown(stepPoints: total, workoutPoints: 0,
                                                    multiplier: 1.0, total: total),
                         goal: goal, isGold: total >= goal, streakAfter: total >= goal ? 1 : 0)
    }

    @Test func upsertIsIdempotentPerDay() throws {
        let store = try makeStore()
        try store.upsert([ledgerDay(0, total: 50)])
        try store.upsert([ledgerDay(0, total: 120)]) // same day, new numbers
        let today = try store.ledger(on: .now)
        #expect(today?.totalPoints == 120)
        let all = try store.ledgers(from: Calendar.current.date(byAdding: .day, value: -5, to: .now)!,
                                    through: .now)
        #expect(all.count == 1)
    }

    @Test func rangeQuerySortedAscending() throws {
        let store = try makeStore()
        try store.upsert([ledgerDay(-2, total: 10), ledgerDay(0, total: 30), ledgerDay(-1, total: 20)])
        let all = try store.ledgers(from: Calendar.current.date(byAdding: .day, value: -2, to: .now)!,
                                    through: .now)
        #expect(all.map(\.totalPoints) == [10, 20, 30])
    }

    @Test func goalProviderUsesStoredGoalForPastDaysOnly() throws {
        let store = try makeStore()
        try store.upsert([ledgerDay(-1, total: 80, goal: 70),
                          ledgerDay(0, total: 90, goal: 70)]) // today already scored under 70
        let provider = store.goalProvider(currentGoal: 150)
        let cal = Calendar.current
        #expect(provider(cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: .now))!) == 70)
        // Today has a stored ledger, but a goal edit must apply to today forward:
        #expect(provider(cal.startOfDay(for: .now)) == 150)
    }

    @Test func workoutUpsertAndPendingSync() throws {
        let store = try makeStore()
        let id = UUID()
        try store.upsertWorkout(id: id, type: .run, start: .now, end: .now.addingTimeInterval(1500),
                                movingSeconds: 1500, distanceMeters: 5000, points: 75,
                                routeData: nil, splitSeconds: [300, 300, 300, 300, 300],
                                source: "runner", hkSynced: false)
        #expect(try store.pendingSync().count == 1)
        // same id upsert flips synced without duplicating
        try store.upsertWorkout(id: id, type: .run, start: .now, end: .now.addingTimeInterval(1500),
                                movingSeconds: 1500, distanceMeters: 5000, points: 75,
                                routeData: nil, splitSeconds: [300, 300, 300, 300, 300],
                                source: "runner", hkSynced: true)
        #expect(try store.pendingSync().isEmpty)
        #expect(try store.allWorkouts().count == 1)
        #expect(try store.workouts(onDay: .now).count == 1)
    }

    @Test func latestLedgerBefore() throws {
        let store = try makeStore()
        try store.upsert([ledgerDay(-3, total: 110), ledgerDay(-2, total: 120)])
        let prior = try store.latestLedger(before: Calendar.current.date(byAdding: .day, value: -1,
                                                                          to: Calendar.current.startOfDay(for: .now))!)
        #expect(prior?.totalPoints == 120)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -20`
Expected: compile failure — `DataStore` not found.

- [ ] **Step 3: Implement models**

`Runner/Core/Store/Models.swift`:

```swift
import Foundation
import SwiftData

@Model
final class DayLedger {
    @Attribute(.unique) var date: Date
    var steps: Int
    var stepPoints: Int
    var workoutPoints: Int
    var multiplier: Double
    var totalPoints: Int
    var goalAtThatTime: Int
    var isGold: Bool
    var streakAfter: Int

    init(date: Date, steps: Int, stepPoints: Int, workoutPoints: Int, multiplier: Double,
         totalPoints: Int, goalAtThatTime: Int, isGold: Bool, streakAfter: Int) {
        self.date = date
        self.steps = steps
        self.stepPoints = stepPoints
        self.workoutPoints = workoutPoints
        self.multiplier = multiplier
        self.totalPoints = totalPoints
        self.goalAtThatTime = goalAtThatTime
        self.isGold = isGold
        self.streakAfter = streakAfter
    }

    func apply(_ day: LedgerDay) {
        steps = day.steps
        stepPoints = day.breakdown.stepPoints
        workoutPoints = day.breakdown.workoutPoints
        multiplier = day.breakdown.multiplier
        totalPoints = day.breakdown.total
        goalAtThatTime = day.goal
        isGold = day.isGold
        streakAfter = day.streakAfter
    }
}

@Model
final class WorkoutRec {
    @Attribute(.unique) var id: UUID
    var typeRaw: String
    var start: Date
    var end: Date
    var movingSeconds: Double
    var distanceMeters: Double
    var points: Int
    var routeData: Data?
    var splitSeconds: [Double]
    var source: String        // "runner" | "external"
    var hkSynced: Bool

    var type: ActivityType { ActivityType(rawValue: typeRaw) ?? .run }

    init(id: UUID, typeRaw: String, start: Date, end: Date, movingSeconds: Double,
         distanceMeters: Double, points: Int, routeData: Data?, splitSeconds: [Double],
         source: String, hkSynced: Bool) {
        self.id = id
        self.typeRaw = typeRaw
        self.start = start
        self.end = end
        self.movingSeconds = movingSeconds
        self.distanceMeters = distanceMeters
        self.points = points
        self.routeData = routeData
        self.splitSeconds = splitSeconds
        self.source = source
        self.hkSynced = hkSynced
    }
}
```

- [ ] **Step 4: Implement DataStore**

`Runner/Core/Store/DataStore.swift`:

```swift
import Foundation
import SwiftData

@MainActor
final class DataStore {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: DayLedger.self, WorkoutRec.self, configurations: config)
    }

    // MARK: Ledger

    func upsert(_ days: [LedgerDay]) throws {
        for day in days {
            if let existing = try ledger(on: day.date) {
                existing.apply(day)
            } else {
                context.insert(DayLedger(date: day.date, steps: day.steps,
                                         stepPoints: day.breakdown.stepPoints,
                                         workoutPoints: day.breakdown.workoutPoints,
                                         multiplier: day.breakdown.multiplier,
                                         totalPoints: day.breakdown.total,
                                         goalAtThatTime: day.goal,
                                         isGold: day.isGold,
                                         streakAfter: day.streakAfter))
            }
        }
        try context.save()
    }

    func ledger(on date: Date) throws -> DayLedger? {
        let day = Calendar.current.startOfDay(for: date)
        var descriptor = FetchDescriptor<DayLedger>(predicate: #Predicate { $0.date == day })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func ledgers(from: Date, through: Date) throws -> [DayLedger] {
        let lo = Calendar.current.startOfDay(for: from)
        let hi = Calendar.current.startOfDay(for: through)
        let descriptor = FetchDescriptor<DayLedger>(
            predicate: #Predicate { $0.date >= lo && $0.date <= hi },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    func latestLedger(before date: Date) throws -> DayLedger? {
        let day = Calendar.current.startOfDay(for: date)
        var descriptor = FetchDescriptor<DayLedger>(
            predicate: #Predicate { $0.date < day },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: Workouts

    @discardableResult
    func upsertWorkout(id: UUID, type: ActivityType, start: Date, end: Date,
                       movingSeconds: Double, distanceMeters: Double, points: Int,
                       routeData: Data?, splitSeconds: [Double],
                       source: String, hkSynced: Bool) throws -> WorkoutRec {
        var descriptor = FetchDescriptor<WorkoutRec>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let rec: WorkoutRec
        if let existing = try context.fetch(descriptor).first {
            existing.typeRaw = type.rawValue
            existing.start = start
            existing.end = end
            existing.movingSeconds = movingSeconds
            existing.distanceMeters = distanceMeters
            existing.points = points
            existing.routeData = routeData ?? existing.routeData
            existing.splitSeconds = splitSeconds
            existing.source = source
            existing.hkSynced = hkSynced
            rec = existing
        } else {
            rec = WorkoutRec(id: id, typeRaw: type.rawValue, start: start, end: end,
                             movingSeconds: movingSeconds, distanceMeters: distanceMeters,
                             points: points, routeData: routeData, splitSeconds: splitSeconds,
                             source: source, hkSynced: hkSynced)
            context.insert(rec)
        }
        try context.save()
        return rec
    }

    func workouts(onDay date: Date) throws -> [WorkoutRec] {
        let cal = Calendar.current
        let lo = cal.startOfDay(for: date)
        let hi = cal.date(byAdding: .day, value: 1, to: lo)!
        let descriptor = FetchDescriptor<WorkoutRec>(
            predicate: #Predicate { $0.start >= lo && $0.start < hi },
            sortBy: [SortDescriptor(\.start, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    func allWorkouts() throws -> [WorkoutRec] {
        try context.fetch(FetchDescriptor<WorkoutRec>(sortBy: [SortDescriptor(\.start, order: .reverse)]))
    }

    func pendingSync() throws -> [WorkoutRec] {
        try context.fetch(FetchDescriptor<WorkoutRec>(
            predicate: #Predicate { $0.source == "runner" && $0.hkSynced == false }
        ))
    }

    // MARK: Goals

    func goalProvider(currentGoal: Int) -> (Date) -> Int {
        let stored: [Date: Int]
        if let all = try? context.fetch(FetchDescriptor<DayLedger>()) {
            stored = Dictionary(uniqueKeysWithValues: all.map { ($0.date, $0.goalAtThatTime) })
        } else {
            stored = [:]
        }
        let todayStart = Calendar.current.startOfDay(for: .now)
        return { date in
            let day = Calendar.current.startOfDay(for: date)
            guard day < todayStart else { return currentGoal } // today forward: live goal
            return stored[day] ?? currentGoal
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -5`
Expected: `TEST SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Runner/Core/Store RunnerTests/DataStoreTests.swift
git commit -m "feat: SwiftData cache — day ledger + workout records with upsert semantics

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: LocationFilter + AutoPauseDetector

**Files:**
- Create: `Runner/Core/Recording/LocationFilter.swift`
- Create: `Runner/Core/Recording/AutoPauseDetector.swift`
- Test: `RunnerTests/LocationFilterTests.swift`
- Test: `RunnerTests/AutoPauseTests.swift`

**Interfaces:**
- Consumes: `ActivityType` (Task 2).
- Produces (relied on by Task 8):

```swift
enum LocationFilter {
    static let maxHorizontalAccuracy: Double = 30   // meters
    static let maxSampleAge: TimeInterval = 10      // seconds
    static let minDisplacementMeters: Double = 3
    static let gapSeconds: TimeInterval = 15

    struct Decision: Equatable { let accepted: Bool; let afterGap: Bool }
    static func evaluate(candidate: CLLocation, lastKept: CLLocation?, now: Date) -> Decision
}

struct AutoPauseDetector {
    private(set) var isPaused: Bool
    init(activity: ActivityType)     // run/walk: pause <0.5 m/s for 10 s; bike: <1.0 m/s for 15 s; resume >threshold for 3 s
    mutating func update(speed: Double, at time: Date) -> Bool   // returns isPaused after this sample
}
```

- [ ] **Step 1: Write failing tests**

`RunnerTests/LocationFilterTests.swift`:

```swift
import Testing
import CoreLocation
@testable import Runner

struct LocationFilterTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func loc(x: Double, y: Double, t: TimeInterval, acc: Double = 5) -> CLLocation {
        let lat = 45.5 + y / 111_320.0
        let lon = -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180))
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                          altitude: 30, horizontalAccuracy: acc, verticalAccuracy: 10,
                          timestamp: base.addingTimeInterval(t))
    }

    @Test func firstSampleAccepted() {
        let d = LocationFilter.evaluate(candidate: loc(x: 0, y: 0, t: 0), lastKept: nil, now: base)
        #expect(d == LocationFilter.Decision(accepted: true, afterGap: false))
    }

    @Test func rejectsBadAccuracy() {
        let d = LocationFilter.evaluate(candidate: loc(x: 0, y: 0, t: 0, acc: 31), lastKept: nil, now: base)
        #expect(d.accepted == false)
        let invalid = LocationFilter.evaluate(candidate: loc(x: 0, y: 0, t: 0, acc: -1), lastKept: nil, now: base)
        #expect(invalid.accepted == false)
    }

    @Test func rejectsStaleSample() {
        let d = LocationFilter.evaluate(candidate: loc(x: 0, y: 0, t: 0),
                                        lastKept: nil, now: base.addingTimeInterval(11))
        #expect(d.accepted == false)
    }

    @Test func rejectsTinyDisplacement() {
        let last = loc(x: 0, y: 0, t: 0)
        let d = LocationFilter.evaluate(candidate: loc(x: 2, y: 0, t: 1), lastKept: last,
                                        now: base.addingTimeInterval(1))
        #expect(d.accepted == false)
    }

    @Test func acceptsNormalMovement() {
        let last = loc(x: 0, y: 0, t: 0)
        let d = LocationFilter.evaluate(candidate: loc(x: 10, y: 0, t: 5), lastKept: last,
                                        now: base.addingTimeInterval(5))
        #expect(d == LocationFilter.Decision(accepted: true, afterGap: false))
    }

    @Test func flagsGapAfterSignalLoss() {
        let last = loc(x: 0, y: 0, t: 0)
        let d = LocationFilter.evaluate(candidate: loc(x: 200, y: 0, t: 60), lastKept: last,
                                        now: base.addingTimeInterval(60))
        #expect(d == LocationFilter.Decision(accepted: true, afterGap: true))
    }
}
```

`RunnerTests/AutoPauseTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

struct AutoPauseTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)
    private func t(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

    @Test func pausesAfterTenSecondsBelowThresholdForRun() {
        var d = AutoPauseDetector(activity: .run)
        #expect(d.update(speed: 3.0, at: t(0)) == false)
        #expect(d.update(speed: 0.2, at: t(1)) == false)   // slow starts counting
        #expect(d.update(speed: 0.1, at: t(9)) == false)   // 8 s below — not yet
        #expect(d.update(speed: 0.1, at: t(11)) == true)   // ≥10 s below → paused
    }

    @Test func briefStopDoesNotPause() {
        var d = AutoPauseDetector(activity: .walk)
        #expect(d.update(speed: 0.1, at: t(0)) == false)
        #expect(d.update(speed: 0.1, at: t(8)) == false)
        #expect(d.update(speed: 1.5, at: t(9)) == false)   // resumed moving before 10 s
        #expect(d.update(speed: 0.1, at: t(10)) == false)  // counter restarted
        #expect(d.update(speed: 0.1, at: t(19)) == false)
        #expect(d.update(speed: 0.1, at: t(21)) == true)
    }

    @Test func resumesAfterThreeSecondsAboveThreshold() {
        var d = AutoPauseDetector(activity: .run)
        _ = d.update(speed: 0.1, at: t(0))
        #expect(d.update(speed: 0.1, at: t(10)) == true)
        #expect(d.update(speed: 2.0, at: t(20)) == true)   // above, starts resume counter
        #expect(d.update(speed: 2.0, at: t(22)) == true)   // 2 s — not yet
        #expect(d.update(speed: 2.0, at: t(23.5)) == false) // ≥3 s → resumed
    }

    @Test func bikeUsesHigherThresholdAndLongerWindow() {
        var d = AutoPauseDetector(activity: .bike)
        #expect(d.update(speed: 0.8, at: t(0)) == false)   // below 1.0 → counting
        #expect(d.update(speed: 0.8, at: t(12)) == false)  // 12 s — bike needs 15
        #expect(d.update(speed: 0.8, at: t(16)) == true)
        // 0.8 m/s would NOT pause a run detector (threshold 0.5)
        var run = AutoPauseDetector(activity: .run)
        #expect(run.update(speed: 0.8, at: t(0)) == false)
        #expect(run.update(speed: 0.8, at: t(20)) == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -20`
Expected: compile failure — `LocationFilter` / `AutoPauseDetector` not found.

- [ ] **Step 3: Implement LocationFilter**

`Runner/Core/Recording/LocationFilter.swift`:

```swift
import CoreLocation

enum LocationFilter {
    static let maxHorizontalAccuracy: Double = 30
    static let maxSampleAge: TimeInterval = 10
    static let minDisplacementMeters: Double = 3
    static let gapSeconds: TimeInterval = 15

    struct Decision: Equatable {
        let accepted: Bool
        let afterGap: Bool
    }

    static func evaluate(candidate: CLLocation, lastKept: CLLocation?, now: Date) -> Decision {
        let reject = Decision(accepted: false, afterGap: false)
        guard candidate.horizontalAccuracy >= 0,
              candidate.horizontalAccuracy <= maxHorizontalAccuracy else { return reject }
        guard now.timeIntervalSince(candidate.timestamp) <= maxSampleAge else { return reject }

        guard let last = lastKept else {
            return Decision(accepted: true, afterGap: false)
        }
        guard candidate.distance(from: last) >= minDisplacementMeters else { return reject }
        let afterGap = candidate.timestamp.timeIntervalSince(last.timestamp) > gapSeconds
        return Decision(accepted: true, afterGap: afterGap)
    }
}
```

- [ ] **Step 4: Implement AutoPauseDetector**

`Runner/Core/Recording/AutoPauseDetector.swift`:

```swift
import Foundation

struct AutoPauseDetector {
    let pauseSpeedThreshold: Double
    let pauseAfter: TimeInterval
    let resumeAfter: TimeInterval = 3

    private(set) var isPaused = false
    private var belowSince: Date?
    private var aboveSince: Date?

    init(activity: ActivityType) {
        switch activity {
        case .run, .walk:
            pauseSpeedThreshold = 0.5
            pauseAfter = 10
        case .bike:
            pauseSpeedThreshold = 1.0
            pauseAfter = 15
        }
    }

    mutating func update(speed: Double, at time: Date) -> Bool {
        if isPaused {
            if speed > pauseSpeedThreshold {
                if aboveSince == nil { aboveSince = time }
                if time.timeIntervalSince(aboveSince!) >= resumeAfter {
                    isPaused = false
                    belowSince = nil
                    aboveSince = nil
                }
            } else {
                aboveSince = nil
            }
        } else {
            if speed < pauseSpeedThreshold {
                if belowSince == nil { belowSince = time }
                if time.timeIntervalSince(belowSince!) >= pauseAfter {
                    isPaused = true
                    aboveSince = nil
                }
            } else {
                belowSince = nil
            }
        }
        return isPaused
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -5`
Expected: `TEST SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Runner/Core/Recording RunnerTests/LocationFilterTests.swift RunnerTests/AutoPauseTests.swift
git commit -m "feat: GPS sample filter and auto-pause state machine

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: RoutePoint + CheckpointStore

**Files:**
- Create: `Runner/Core/Recording/RoutePoint.swift`
- Create: `Runner/Core/Recording/CheckpointStore.swift`
- Test: `RunnerTests/CheckpointStoreTests.swift`

**Interfaces:**
- Consumes: `ActivityType` (Task 2).
- Produces (relied on by Tasks 8, 12, 13, 14, 15):

```swift
struct RoutePoint: Codable, Equatable, Sendable {
    let lat: Double
    let lon: Double
    let t: Date
    let afterGap: Bool
}

extension [RoutePoint] {
    func encoded() throws -> Data                       // JSON
    static func decode(_ data: Data) -> [RoutePoint]    // [] on failure
}

struct SessionCheckpoint: Codable, Equatable {
    let activity: ActivityType
    let startedAt: Date
    let movingSeconds: Double
    let distanceMeters: Double
    let route: [RoutePoint]
    let splitSeconds: [Double]
    let savedAt: Date
}

struct CheckpointStore {
    init(directory: URL? = nil)   // default: Application Support/Runner/
    func save(_ checkpoint: SessionCheckpoint) throws   // atomic write to checkpoint.json
    func load() -> SessionCheckpoint?                   // nil if absent or corrupt
    func clear()
}
```

- [ ] **Step 1: Write failing tests**

`RunnerTests/CheckpointStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

struct CheckpointStoreTests {
    private func tempStore() -> CheckpointStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-tests-\(UUID().uuidString)")
        return CheckpointStore(directory: dir)
    }

    private var sample: SessionCheckpoint {
        SessionCheckpoint(activity: .bike,
                          startedAt: Date(timeIntervalSince1970: 1_750_000_000),
                          movingSeconds: 340,
                          distanceMeters: 2_450,
                          route: [RoutePoint(lat: 45.5, lon: -73.6,
                                             t: Date(timeIntervalSince1970: 1_750_000_100),
                                             afterGap: false)],
                          splitSeconds: [301.5, 322.0],
                          savedAt: Date(timeIntervalSince1970: 1_750_000_340))
    }

    @Test func roundTrip() throws {
        let store = tempStore()
        try store.save(sample)
        #expect(store.load() == sample)
    }

    @Test func loadWithoutSaveReturnsNil() {
        #expect(tempStore().load() == nil)
    }

    @Test func clearRemovesCheckpoint() throws {
        let store = tempStore()
        try store.save(sample)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test func corruptFileReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-tests-\(UUID().uuidString)")
        let store = CheckpointStore(directory: dir)
        try store.save(sample) // creates directory
        try Data("not json".utf8).write(to: dir.appendingPathComponent("checkpoint.json"))
        #expect(store.load() == nil)
    }

    @Test func routePointArrayCodableRoundTrip() throws {
        let points = [RoutePoint(lat: 1, lon: 2, t: .init(timeIntervalSince1970: 3), afterGap: true)]
        let data = try points.encoded()
        #expect([RoutePoint].decode(data) == points)
        #expect([RoutePoint].decode(Data("junk".utf8)) == [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -20`
Expected: compile failure — `RoutePoint` / `CheckpointStore` not found.

- [ ] **Step 3: Implement**

`Runner/Core/Recording/RoutePoint.swift`:

```swift
import Foundation

struct RoutePoint: Codable, Equatable, Sendable {
    let lat: Double
    let lon: Double
    let t: Date
    let afterGap: Bool
}

extension [RoutePoint] {
    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> [RoutePoint] {
        (try? JSONDecoder().decode([RoutePoint].self, from: data)) ?? []
    }
}
```

`Runner/Core/Recording/CheckpointStore.swift`:

```swift
import Foundation

struct SessionCheckpoint: Codable, Equatable {
    let activity: ActivityType
    let startedAt: Date
    let movingSeconds: Double
    let distanceMeters: Double
    let route: [RoutePoint]
    let splitSeconds: [Double]
    let savedAt: Date
}

struct CheckpointStore {
    let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("checkpoint.json") }

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
            self.directory = base.appendingPathComponent("Runner", isDirectory: true)
        }
    }

    func save(_ checkpoint: SessionCheckpoint) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: fileURL, options: .atomic)
    }

    func load() -> SessionCheckpoint? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionCheckpoint.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -5`
Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Runner/Core/Recording/RoutePoint.swift Runner/Core/Recording/CheckpointStore.swift RunnerTests/CheckpointStoreTests.swift
git commit -m "feat: route points and crash-safe session checkpoints

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: WorkoutRecorder

**Files:**
- Create: `Runner/Core/Recording/LocationProviding.swift`
- Create: `Runner/Core/Recording/SystemLocationProvider.swift`
- Create: `Runner/Core/Recording/WorkoutRecorder.swift`
- Test: `RunnerTests/WorkoutRecorderTests.swift`

**Interfaces:**
- Consumes: `LocationFilter`, `AutoPauseDetector` (Task 6), `RoutePoint`, `SessionCheckpoint`, `CheckpointStore` (Task 7), `PointsEngine.livePoints` (Task 3).
- Produces (relied on by Tasks 12, 13):

```swift
@MainActor protocol LocationProviding: AnyObject {
    var delegate: LocationProvidingDelegate? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    func requestWhenInUseAuthorization()
    func startUpdates()
    func stopUpdates()
}

@MainActor protocol LocationProvidingDelegate: AnyObject {
    func didUpdate(locations: [CLLocation])
    func didChangeAuthorization(_ status: CLAuthorizationStatus)
    func didFail(_ error: Error)
}

struct RecordedWorkout: Equatable, Sendable {
    let type: ActivityType
    let start: Date
    let end: Date
    let movingSeconds: Double
    let distanceMeters: Double
    let route: [RoutePoint]
    let splitSeconds: [Double]
}

@MainActor @Observable final class WorkoutRecorder: LocationProvidingDelegate {
    enum State: Equatable { case idle, recording, autoPaused, manuallyPaused }
    private(set) var state: State
    private(set) var activity: ActivityType
    private(set) var startedAt: Date?
    private(set) var movingSeconds: Double
    private(set) var distanceMeters: Double
    private(set) var route: [RoutePoint]
    private(set) var splitSeconds: [Double]
    private(set) var authorizationDenied: Bool
    var livePoints: Int { get }                 // PointsEngine.livePoints
    var paceSecondsPerKm: Double? { get }       // nil under 100 m
    var onKmSplit: ((Int) -> Void)?             // Task 17 hooks haptics here

    init(provider: LocationProviding, checkpoints: CheckpointStore = CheckpointStore(),
         checkpointInterval: TimeInterval = 30)
    func requestPermission()
    func start(activity: ActivityType, resumeFrom: SessionCheckpoint? = nil)
    func pauseManually()
    func resumeManually()
    func finish() -> RecordedWorkout            // stops updates, clears checkpoint, resets to idle
    func discard()                              // stops updates, clears checkpoint, resets
}
```

Behavior contract (all encoded in the tests below): moving time accrues only between accepted samples while `.recording`, capped at 10 s per interval; distance is not credited across a gap (`afterGap`) nor while paused; the auto-pause detector is fed **every** sample (even rejected ones) so standing still pauses; manual pause ignores samples entirely; checkpoints are written when an accepted sample arrives ≥ `checkpointInterval` after the previous checkpoint; `finish()` clears the checkpoint.

- [ ] **Step 1: Write failing tests**

`RunnerTests/WorkoutRecorderTests.swift`:

```swift
import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
final class FakeLocationProvider: LocationProviding {
    weak var delegate: LocationProvidingDelegate?
    var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    var started = false
    var stopped = false
    func requestWhenInUseAuthorization() {}
    func startUpdates() { started = true }
    func stopUpdates() { stopped = true }
}

@MainActor
struct WorkoutRecorderTests {
    // Synthetic clock anchored near now so LocationFilter's age check passes.
    private let base = Date().addingTimeInterval(-2)

    private func loc(x: Double, t: TimeInterval, acc: Double = 5, speed: Double = 2.5) -> CLLocation {
        let lat = 45.5
        let lon = -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180))
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                          altitude: 30, horizontalAccuracy: acc, verticalAccuracy: 10,
                          course: 90, speed: speed, timestamp: base.addingTimeInterval(t))
    }

    private func makeRecorder(interval: TimeInterval = 30) -> (WorkoutRecorder, FakeLocationProvider, CheckpointStore) {
        let provider = FakeLocationProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-tests-\(UUID().uuidString)")
        let cp = CheckpointStore(directory: dir)
        let recorder = WorkoutRecorder(provider: provider, checkpoints: cp, checkpointInterval: interval)
        return (recorder, provider, cp)
    }

    @Test func accumulatesDistanceAndMovingTime() {
        let (rec, provider, _) = makeRecorder()
        rec.start(activity: .walk)
        #expect(provider.started)
        // 11 samples, 10 m apart, 4 s apart (2.5 m/s = brisk walk)
        for i in 0...10 { rec.didUpdate(locations: [loc(x: Double(i) * 10, t: Double(i) * 4)]) }
        #expect(abs(rec.distanceMeters - 100) < 2)
        #expect(abs(rec.movingSeconds - 40) < 0.5)
        #expect(rec.route.count == 11)
        #expect(rec.state == .recording)
        #expect(rec.livePoints == 1) // floor(0.1 km × 10)
    }

    @Test func gapCreditsNoDistance() {
        let (rec, _, _) = makeRecorder()
        rec.start(activity: .run)
        rec.didUpdate(locations: [loc(x: 0, t: 0)])
        rec.didUpdate(locations: [loc(x: 10, t: 4)])
        // signal lost for 60 s, reappears 500 m away
        rec.didUpdate(locations: [loc(x: 510, t: 64)])
        #expect(abs(rec.distanceMeters - 10) < 1)          // 500 m NOT credited
        #expect(rec.route.last?.afterGap == true)
        #expect(rec.movingSeconds < 15)                    // gap interval capped at 10 s
    }

    @Test func autoPausesWhenStandingStill() {
        let (rec, _, _) = makeRecorder()
        rec.start(activity: .run)
        rec.didUpdate(locations: [loc(x: 0, t: 0)])
        rec.didUpdate(locations: [loc(x: 10, t: 4)])
        // standing still: same spot, speed 0, samples every 2 s for 12 s
        for i in 1...6 {
            rec.didUpdate(locations: [loc(x: 10.5, t: 4 + Double(i) * 2, speed: 0.0)])
        }
        #expect(rec.state == .autoPaused)
        let frozen = rec.distanceMeters
        // moving again: ≥3 s above threshold resumes; the first post-resume sample
        // arrives >15 s after the last kept one, so it is a gap point (no distance) —
        // distance grows again from the sample after it.
        rec.didUpdate(locations: [loc(x: 20, t: 20)])
        rec.didUpdate(locations: [loc(x: 30, t: 24)])
        #expect(rec.state == .recording)
        rec.didUpdate(locations: [loc(x: 40, t: 27)])
        #expect(rec.distanceMeters > frozen)
    }

    @Test func manualPauseIgnoresSamples() {
        let (rec, _, _) = makeRecorder()
        rec.start(activity: .bike)
        rec.didUpdate(locations: [loc(x: 0, t: 0)])
        rec.pauseManually()
        #expect(rec.state == .manuallyPaused)
        rec.didUpdate(locations: [loc(x: 100, t: 10)])
        #expect(rec.distanceMeters < 1)
        rec.resumeManually()
        #expect(rec.state == .recording)
    }

    @Test func recordsKmSplits() {
        let (rec, _, _) = makeRecorder()
        rec.start(activity: .run)
        var splits: [Int] = []
        rec.onKmSplit = { splits.append($0) }
        // 1,100 m in 110 samples of 10 m, 3 s apart
        for i in 0...110 { rec.didUpdate(locations: [loc(x: Double(i) * 10, t: Double(i) * 3)]) }
        #expect(rec.splitSeconds.count == 1)
        #expect(splits == [1])
        #expect(abs(rec.splitSeconds[0] - 300) < 10) // ~100 samples × 3 s
    }

    @Test func checkpointsPeriodicallyAndFinishClears() throws {
        let (rec, provider, cp) = makeRecorder(interval: 5)
        rec.start(activity: .walk)
        for i in 0...3 { rec.didUpdate(locations: [loc(x: Double(i) * 10, t: Double(i) * 2)]) }
        #expect(cp.load() != nil)                     // ≥5 s elapsed → checkpointed
        let saved = try #require(cp.load())
        #expect(saved.activity == .walk)
        #expect(saved.distanceMeters > 0)
        let done = rec.finish()
        #expect(provider.stopped)
        #expect(cp.load() == nil)
        #expect(rec.state == .idle)
        #expect(abs(done.distanceMeters - 30) < 2)
        #expect(done.type == .walk)
    }

    @Test func resumeFromCheckpointRestoresProgress() {
        let (rec, _, _) = makeRecorder()
        let checkpoint = SessionCheckpoint(activity: .run, startedAt: base,
                                           movingSeconds: 120, distanceMeters: 800,
                                           route: [RoutePoint(lat: 45.5, lon: -73.6, t: base, afterGap: false)],
                                           splitSeconds: [], savedAt: base)
        rec.start(activity: .run, resumeFrom: checkpoint)
        #expect(rec.distanceMeters == 800)
        #expect(rec.movingSeconds == 120)
        #expect(rec.route.count == 1)
        #expect(rec.state == .recording)
    }

    @Test func deniedAuthorizationSetsFlag() {
        let (rec, _, _) = makeRecorder()
        rec.didChangeAuthorization(.denied)
        #expect(rec.authorizationDenied)
        rec.didChangeAuthorization(.authorizedWhenInUse)
        #expect(rec.authorizationDenied == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -20`
Expected: compile failure — `WorkoutRecorder` / `LocationProviding` not found.

- [ ] **Step 3: Implement the protocols**

`Runner/Core/Recording/LocationProviding.swift`:

```swift
import CoreLocation

@MainActor
protocol LocationProviding: AnyObject {
    var delegate: LocationProvidingDelegate? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    func requestWhenInUseAuthorization()
    func startUpdates()
    func stopUpdates()
}

@MainActor
protocol LocationProvidingDelegate: AnyObject {
    func didUpdate(locations: [CLLocation])
    func didChangeAuthorization(_ status: CLAuthorizationStatus)
    func didFail(_ error: Error)
}
```

- [ ] **Step 4: Implement the system provider**

`Runner/Core/Recording/SystemLocationProvider.swift`:

```swift
import CoreLocation

@MainActor
final class SystemLocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    weak var delegate: LocationProvidingDelegate?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.distanceFilter = 3
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdates() {
        // Requires the "location" UIBackgroundModes entry (present since Task 1)
        // and an in-foreground start; keeps recording with the screen off.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stopUpdates() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    // MARK: CLLocationManagerDelegate (callbacks hop to MainActor)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.delegate?.didUpdate(locations: locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.delegate?.didChangeAuthorization(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.delegate?.didFail(error) }
    }
}
```

- [ ] **Step 5: Implement WorkoutRecorder**

`Runner/Core/Recording/WorkoutRecorder.swift`:

```swift
import Foundation
import CoreLocation
import Observation

struct RecordedWorkout: Equatable, Sendable {
    let type: ActivityType
    let start: Date
    let end: Date
    let movingSeconds: Double
    let distanceMeters: Double
    let route: [RoutePoint]
    let splitSeconds: [Double]
}

@MainActor
@Observable
final class WorkoutRecorder: LocationProvidingDelegate {
    enum State: Equatable { case idle, recording, autoPaused, manuallyPaused }

    private(set) var state: State = .idle
    private(set) var activity: ActivityType = .run
    private(set) var startedAt: Date?
    private(set) var movingSeconds: Double = 0
    private(set) var distanceMeters: Double = 0
    private(set) var route: [RoutePoint] = []
    private(set) var splitSeconds: [Double] = []
    private(set) var authorizationDenied = false

    var livePoints: Int { PointsEngine.livePoints(type: activity, distanceMeters: distanceMeters) }
    var paceSecondsPerKm: Double? {
        guard distanceMeters >= 100 else { return nil }
        return movingSeconds / (distanceMeters / 1000.0)
    }
    var onKmSplit: ((Int) -> Void)?

    private let provider: LocationProviding
    private let checkpoints: CheckpointStore
    private let checkpointInterval: TimeInterval
    private var lastKeptLocation: CLLocation?
    private var autoPause: AutoPauseDetector?
    private var lastCheckpointAt: Date?
    private var lastSplitMovingSeconds: Double = 0

    init(provider: LocationProviding,
         checkpoints: CheckpointStore = CheckpointStore(),
         checkpointInterval: TimeInterval = 30) {
        self.provider = provider
        self.checkpoints = checkpoints
        self.checkpointInterval = checkpointInterval
        provider.delegate = self
    }

    func requestPermission() {
        provider.requestWhenInUseAuthorization()
    }

    func start(activity: ActivityType, resumeFrom checkpoint: SessionCheckpoint? = nil) {
        self.activity = activity
        if let checkpoint {
            startedAt = checkpoint.startedAt
            movingSeconds = checkpoint.movingSeconds
            distanceMeters = checkpoint.distanceMeters
            route = checkpoint.route
            splitSeconds = checkpoint.splitSeconds
            lastSplitMovingSeconds = checkpoint.splitSeconds.reduce(0, +)
        } else {
            startedAt = Date()
            movingSeconds = 0
            distanceMeters = 0
            route = []
            splitSeconds = []
            lastSplitMovingSeconds = 0
        }
        lastKeptLocation = nil
        lastCheckpointAt = nil
        autoPause = AutoPauseDetector(activity: activity)
        state = .recording
        provider.startUpdates()
    }

    func pauseManually() {
        guard state == .recording || state == .autoPaused else { return }
        state = .manuallyPaused
        saveCheckpoint(at: Date())
    }

    func resumeManually() {
        guard state == .manuallyPaused else { return }
        autoPause = AutoPauseDetector(activity: activity)
        lastKeptLocation = nil // fresh segment; gap marker will show honestly
        state = .recording
    }

    func finish() -> RecordedWorkout {
        provider.stopUpdates()
        let workout = RecordedWorkout(type: activity,
                                      start: startedAt ?? Date(),
                                      end: Date(),
                                      movingSeconds: movingSeconds,
                                      distanceMeters: distanceMeters,
                                      route: route,
                                      splitSeconds: splitSeconds)
        checkpoints.clear()
        reset()
        return workout
    }

    func discard() {
        provider.stopUpdates()
        checkpoints.clear()
        reset()
    }

    private func reset() {
        state = .idle
        startedAt = nil
        movingSeconds = 0
        distanceMeters = 0
        route = []
        splitSeconds = []
        lastKeptLocation = nil
        lastCheckpointAt = nil
        autoPause = nil
        lastSplitMovingSeconds = 0
    }

    // MARK: LocationProvidingDelegate

    func didUpdate(locations: [CLLocation]) {
        for location in locations { ingest(location) }
    }

    func didChangeAuthorization(_ status: CLAuthorizationStatus) {
        authorizationDenied = (status == .denied || status == .restricted)
    }

    func didFail(_ error: Error) {
        // GPS hiccups: keep the session alive; the gap logic handles the hole.
    }

    // MARK: Core ingestion

    private func ingest(_ location: CLLocation) {
        guard state == .recording || state == .autoPaused else { return }

        // 1. Speed for auto-pause: sensor speed, else computed from last kept point.
        let sensorSpeed = location.speed
        let computedSpeed: Double
        if let last = lastKeptLocation {
            let dt = location.timestamp.timeIntervalSince(last.timestamp)
            computedSpeed = dt > 0 ? location.distance(from: last) / dt : 0
        } else {
            computedSpeed = 0
        }
        let speed = sensorSpeed >= 0 ? sensorSpeed : computedSpeed

        // 2. Feed the detector on EVERY sample so standing still triggers a pause.
        if var detector = autoPause {
            let paused = detector.update(speed: speed, at: location.timestamp)
            autoPause = detector
            state = paused ? .autoPaused : .recording
        }

        // 3. Accept or reject the sample.
        let decision = LocationFilter.evaluate(candidate: location,
                                               lastKept: lastKeptLocation,
                                               now: Date())
        guard decision.accepted, state == .recording else { return }

        // 4. Credit moving time (capped) and distance (not across gaps).
        if let last = lastKeptLocation {
            let dt = min(location.timestamp.timeIntervalSince(last.timestamp),
                         LocationFilter.maxSampleAge)
            if dt > 0 { movingSeconds += dt }
            if !decision.afterGap {
                distanceMeters += location.distance(from: last)
            }
        }
        route.append(RoutePoint(lat: location.coordinate.latitude,
                                lon: location.coordinate.longitude,
                                t: location.timestamp,
                                afterGap: decision.afterGap))
        lastKeptLocation = location

        // 5. Km splits.
        let completedKm = Int(distanceMeters / 1000.0)
        while splitSeconds.count < completedKm {
            splitSeconds.append(movingSeconds - lastSplitMovingSeconds)
            lastSplitMovingSeconds = movingSeconds
            onKmSplit?(splitSeconds.count)
        }

        // 6. Periodic checkpoint.
        if lastCheckpointAt == nil ||
            location.timestamp.timeIntervalSince(lastCheckpointAt!) >= checkpointInterval {
            saveCheckpoint(at: location.timestamp)
        }
    }

    private func saveCheckpoint(at time: Date) {
        guard let startedAt else { return }
        let checkpoint = SessionCheckpoint(activity: activity, startedAt: startedAt,
                                           movingSeconds: movingSeconds,
                                           distanceMeters: distanceMeters,
                                           route: route, splitSeconds: splitSeconds,
                                           savedAt: time)
        try? checkpoints.save(checkpoint)
        lastCheckpointAt = time
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -8`
Expected: `TEST SUCCEEDED`. If `autoPausesWhenStandingStill` is flaky, check that the still samples' `speed: 0.0` reaches the detector before the displacement filter rejects them (step order in `ingest` matters — detector first).

- [ ] **Step 7: Commit**

```bash
git add Runner/Core/Recording RunnerTests/WorkoutRecorderTests.swift
git commit -m "feat: workout recorder — GPS session with auto-pause, gaps, splits, checkpoints

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 9: HealthStore (HealthKit Gateway)

**Files:**
- Create: `Runner/Core/Health/HealthStoring.swift`
- Create: `Runner/Core/Health/HealthMappers.swift`
- Create: `Runner/Core/Health/HealthStore.swift`
- Test: `RunnerTests/HealthMappersTests.swift`

**Interfaces:**
- Consumes: `ActivityType` (Task 2), `WorkoutSummary` (Task 3), `RecordedWorkout` (Task 8).
- Produces (relied on by Tasks 10, 11, 12, 13):

```swift
struct ExternalWorkout: Equatable, Sendable {
    let id: UUID
    let type: ActivityType
    let start: Date
    let distanceMeters: Double
    let isFromThisApp: Bool
}

@MainActor protocol HealthStoring: AnyObject {
    var isAvailable: Bool { get }                 // HKHealthStore.isHealthDataAvailable()
    var writeDenied: Bool { get }                 // sharing denied for workouts
    func requestAuthorization() async throws
    func shouldRequestAuthorization() async -> Bool
    func dailySteps(daysBack: Int) async throws -> [Date: Int]      // keys are local startOfDay
    func workouts(daysBack: Int) async throws -> [ExternalWorkout]  // ALL run/walk/bike workouts in window
    func saveWorkout(_ workout: RecordedWorkout, points: Int) async throws -> UUID
    func startObservingSteps(_ onChange: @escaping @Sendable () -> Void)
}

enum HealthMappers {
    static func activityType(from hk: HKWorkoutActivityType) -> ActivityType?  // running/walking/cycling else nil
    static func hkActivityType(for type: ActivityType) -> HKWorkoutActivityType
    static func window(daysBack: Int, endingAt now: Date, calendar: Calendar) -> (start: Date, end: Date)
    static func groupByDay(_ workouts: [ExternalWorkout], calendar: Calendar) -> [Date: [WorkoutSummary]]
}
```

The real `HealthStore` can only be fully exercised on a device (simulator HealthKit has no step data); its pure mapping logic is what we unit-test. Task 18 validates the real store end-to-end.

- [ ] **Step 1: Write failing mapper tests**

`RunnerTests/HealthMappersTests.swift`:

```swift
import Testing
import Foundation
import HealthKit
@testable import Runner

struct HealthMappersTests {
    @Test func activityTypeMapping() {
        #expect(HealthMappers.activityType(from: .running) == .run)
        #expect(HealthMappers.activityType(from: .walking) == .walk)
        #expect(HealthMappers.activityType(from: .cycling) == .bike)
        #expect(HealthMappers.activityType(from: .yoga) == nil)
        #expect(HealthMappers.hkActivityType(for: .run) == .running)
        #expect(HealthMappers.hkActivityType(for: .walk) == .walking)
        #expect(HealthMappers.hkActivityType(for: .bike) == .cycling)
    }

    @Test func windowSpansRequestedDays() {
        let cal = Calendar.current
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let (start, end) = HealthMappers.window(daysBack: 90, endingAt: now, calendar: cal)
        #expect(end == now)
        #expect(start == cal.date(byAdding: .day, value: -(90 - 1), to: cal.startOfDay(for: now)))
        // window includes today → 90 distinct days total
    }

    @Test func groupsWorkoutsByLocalDay() {
        let cal = Calendar.current
        let now = Date()
        let todayNoon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        let yesterdayNoon = cal.date(byAdding: .day, value: -1, to: todayNoon)!
        let list = [
            ExternalWorkout(id: UUID(), type: .run, start: todayNoon, distanceMeters: 5000, isFromThisApp: false),
            ExternalWorkout(id: UUID(), type: .bike, start: todayNoon.addingTimeInterval(3600),
                            distanceMeters: 10_000, isFromThisApp: true),
            ExternalWorkout(id: UUID(), type: .walk, start: yesterdayNoon, distanceMeters: 2000, isFromThisApp: false),
        ]
        let grouped = HealthMappers.groupByDay(list, calendar: cal)
        #expect(grouped[cal.startOfDay(for: todayNoon)]?.count == 2)
        #expect(grouped[cal.startOfDay(for: yesterdayNoon)] ==
                [WorkoutSummary(type: .walk, distanceMeters: 2000)])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -20`
Expected: compile failure — `HealthMappers` not found.

- [ ] **Step 3: Implement protocol + mappers**

`Runner/Core/Health/HealthStoring.swift`:

```swift
import Foundation
import HealthKit

struct ExternalWorkout: Equatable, Sendable {
    let id: UUID
    let type: ActivityType
    let start: Date
    let distanceMeters: Double
    let isFromThisApp: Bool
}

@MainActor
protocol HealthStoring: AnyObject {
    var isAvailable: Bool { get }
    var writeDenied: Bool { get }
    func requestAuthorization() async throws
    func shouldRequestAuthorization() async -> Bool
    func dailySteps(daysBack: Int) async throws -> [Date: Int]
    func workouts(daysBack: Int) async throws -> [ExternalWorkout]
    func saveWorkout(_ workout: RecordedWorkout, points: Int) async throws -> UUID
    func startObservingSteps(_ onChange: @escaping @Sendable () -> Void)
}
```

`Runner/Core/Health/HealthMappers.swift`:

```swift
import Foundation
import HealthKit

enum HealthMappers {
    static func activityType(from hk: HKWorkoutActivityType) -> ActivityType? {
        switch hk {
        case .running: .run
        case .walking: .walk
        case .cycling: .bike
        default: nil
        }
    }

    static func hkActivityType(for type: ActivityType) -> HKWorkoutActivityType {
        switch type {
        case .run: .running
        case .walk: .walking
        case .bike: .cycling
        }
    }

    static func window(daysBack: Int, endingAt now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let start = calendar.date(byAdding: .day, value: -(daysBack - 1),
                                  to: calendar.startOfDay(for: now))!
        return (start, now)
    }

    static func groupByDay(_ workouts: [ExternalWorkout], calendar: Calendar) -> [Date: [WorkoutSummary]] {
        var out: [Date: [WorkoutSummary]] = [:]
        for w in workouts.sorted(by: { $0.start < $1.start }) {
            let day = calendar.startOfDay(for: w.start)
            out[day, default: []].append(WorkoutSummary(type: w.type, distanceMeters: w.distanceMeters))
        }
        return out
    }
}
```

- [ ] **Step 4: Implement the real HealthKit store**

`Runner/Core/Health/HealthStore.swift`:

```swift
import Foundation
import HealthKit
import CoreLocation

@MainActor
final class HealthStore: HealthStoring {
    private let store = HKHealthStore()
    private let stepType = HKQuantityType(.stepCount)
    private let workoutType = HKObjectType.workoutType()
    private let routeType = HKSeriesType.workoutRoute()
    private let distanceWalkRun = HKQuantityType(.distanceWalkingRunning)
    private let distanceCycling = HKQuantityType(.distanceCycling)

    static let pointsMetadataKey = "com.farid.runner.points"

    private var shareTypes: Set<HKSampleType> {
        [workoutType, routeType, distanceWalkRun, distanceCycling]
    }
    private var readTypes: Set<HKObjectType> {
        [stepType, workoutType, routeType, distanceWalkRun, distanceCycling]
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    var writeDenied: Bool { store.authorizationStatus(for: workoutType) == .sharingDenied }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    func shouldRequestAuthorization() async -> Bool {
        let status = try? await store.statusForAuthorizationRequest(toShare: shareTypes, read: readTypes)
        return status == .shouldRequest
    }

    func dailySteps(daysBack: Int) async throws -> [Date: Int] {
        let cal = Calendar.current
        let (start, end) = HealthMappers.window(daysBack: daysBack, endingAt: Date(), calendar: cal)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: stepType,
                                                    quantitySamplePredicate: predicate,
                                                    options: .cumulativeSum,
                                                    anchorDate: start,
                                                    intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var out: [Date: Int] = [:]
                collection?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let steps = stats.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    out[cal.startOfDay(for: stats.startDate)] = Int(steps)
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }

    func workouts(daysBack: Int) async throws -> [ExternalWorkout] {
        let cal = Calendar.current
        let (start, end) = HealthMappers.window(daysBack: daysBack, endingAt: Date(), calendar: cal)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: workoutType, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                                          ascending: true)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.farid.runner"
        return samples.compactMap { sample in
            guard let workout = sample as? HKWorkout,
                  let type = HealthMappers.activityType(from: workout.workoutActivityType) else { return nil }
            let distanceType = (type == .bike) ? distanceCycling : distanceWalkRun
            let meters = workout.statistics(for: distanceType)?.sumQuantity()?
                .doubleValue(for: .meter()) ?? 0
            return ExternalWorkout(id: workout.uuid, type: type, start: workout.startDate,
                                   distanceMeters: meters,
                                   isFromThisApp: workout.sourceRevision.source.bundleIdentifier == bundleID)
        }
    }

    func saveWorkout(_ workout: RecordedWorkout, points: Int) async throws -> UUID {
        let config = HKWorkoutConfiguration()
        config.activityType = HealthMappers.hkActivityType(for: workout.type)
        config.locationType = .outdoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        try await builder.beginCollection(at: workout.start)

        if workout.distanceMeters > 0 {
            let distanceType = (workout.type == .bike) ? distanceCycling : distanceWalkRun
            let sample = HKQuantitySample(type: distanceType,
                                          quantity: HKQuantity(unit: .meter(),
                                                               doubleValue: workout.distanceMeters),
                                          start: workout.start, end: workout.end)
            try await builder.addSamples([sample])
        }
        try await builder.addMetadata([Self.pointsMetadataKey: points])
        try await builder.endCollection(at: workout.end)
        // SDK note: async finishWorkout() is optional in current SDKs; if this SDK
        // version returns non-optional, drop the guard and bind directly.
        guard let hkWorkout = try await builder.finishWorkout() else {
            throw NSError(domain: "Runner", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "HealthKit returned no workout"])
        }

        // Attach the GPS route (needs ≥2 locations).
        let locations = workout.route.map {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                       altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: $0.t)
        }
        if locations.count >= 2 {
            let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
            try await routeBuilder.insertRouteData(locations)
            try await routeBuilder.finishRoute(with: hkWorkout, metadata: nil)
        }
        return hkWorkout.uuid
    }

    func startObservingSteps(_ onChange: @escaping @Sendable () -> Void) {
        let query = HKObserverQuery(sampleType: stepType, predicate: nil) { _, completion, _ in
            onChange()
            completion()
        }
        store.execute(query)
        store.enableBackgroundDelivery(for: stepType, frequency: .hourly) { _, _ in }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -5`
Expected: `TEST SUCCEEDED` (mapper tests pass; HealthStore compiles).

- [ ] **Step 6: Commit**

```bash
git add Runner/Core/Health RunnerTests/HealthMappersTests.swift
git commit -m "feat: HealthKit gateway — steps/workouts read, workout+route write

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: SyncCoordinator

**Files:**
- Create: `Runner/Core/Store/SyncCoordinator.swift`
- Create: `RunnerTests/FakeHealthStore.swift`
- Test: `RunnerTests/SyncCoordinatorTests.swift`

**Interfaces:**
- Consumes: `HealthStoring`, `ExternalWorkout`, `HealthMappers` (Task 9), `DataStore` (Task 5), `LedgerBuilder`/`DayActivity` (Task 4), `PointsEngine` (Task 3), `RecordedWorkout` (Task 8), `[RoutePoint].decode` (Task 7).
- Produces (relied on by Tasks 11, 12, 13):

```swift
@MainActor final class SyncCoordinator {
    static let windowDays = 90
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    private(set) var isSyncing: Bool
    init(health: HealthStoring, store: DataStore, currentGoal: @escaping () -> Int)
    func syncNow() async        // never throws; records lastError instead
}
```

Sync algorithm (the contract):
1. Retry every `store.pendingSync()` workout against `health.saveWorkout`; on success re-upsert with `hkSynced: true` (same local id — external reads exclude our app's workouts by bundle id, so ids never need reconciling).
2. Read `dailySteps(daysBack: 90)` and `workouts(daysBack: 90)` from HealthKit.
3. Upsert every HK workout **not from this app** into the cache with `source: "external"`, `routeData: nil`, points = `PointsEngine.workoutPoints`.
4. Build day inputs for each of the 90 days ascending: steps from the map (0 if absent), workouts = HK workouts grouped by day **plus** still-pending local workouts (they're not in HK yet).
5. `LedgerBuilder.build` with `initialStreak = store.latestLedger(before: windowStart)?.streakAfter ?? 0` and `goalProvider = store.goalProvider(currentGoal: currentGoal())`, then `store.upsert`.
6. Set `lastSyncAt`; on any thrown error set `lastError` (localized description) and keep whatever succeeded.

- [ ] **Step 1: Write the fake + failing tests**

`RunnerTests/FakeHealthStore.swift`:

```swift
import Foundation
@testable import Runner

@MainActor
final class FakeHealthStore: HealthStoring {
    var isAvailable = true
    var writeDenied = false
    var stepsByDay: [Date: Int] = [:]
    var cannedWorkouts: [ExternalWorkout] = []
    var saveError: Error?
    var savedWorkouts: [(RecordedWorkout, Int)] = []
    var observers: [() -> Void] = []

    func requestAuthorization() async throws {}
    func shouldRequestAuthorization() async -> Bool { false }
    func dailySteps(daysBack: Int) async throws -> [Date: Int] { stepsByDay }
    func workouts(daysBack: Int) async throws -> [ExternalWorkout] { cannedWorkouts }

    func saveWorkout(_ workout: RecordedWorkout, points: Int) async throws -> UUID {
        if let saveError { throw saveError }
        savedWorkouts.append((workout, points))
        return UUID()
    }

    func startObservingSteps(_ onChange: @escaping @Sendable () -> Void) {
        observers.append(onChange)
    }
}
```

`RunnerTests/SyncCoordinatorTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

@MainActor
struct SyncCoordinatorTests {
    private func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: .now))!
    }

    private func make(goal: Int = 100) throws -> (SyncCoordinator, FakeHealthStore, DataStore) {
        let health = FakeHealthStore()
        let store = try DataStore(inMemory: true)
        let sync = SyncCoordinator(health: health, store: store, currentGoal: { goal })
        return (sync, health, store)
    }

    @Test func backfillBuildsLedgersWithStreaks() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(-2): 12_000, day(-1): 3_000, day(0): 8_450]
        health.cannedWorkouts = [
            ExternalWorkout(id: UUID(), type: .run,
                            start: day(0).addingTimeInterval(9 * 3600),
                            distanceMeters: 2_100, isFromThisApp: false)
        ]
        await sync.syncNow()
        #expect(sync.lastError == nil)
        // day -2: 120 pts gold; day -1: 30 pts not gold; day 0: (84+32)×1.0 = 116 gold
        #expect(try store.ledger(on: day(-2))?.totalPoints == 120)
        #expect(try store.ledger(on: day(-1))?.isGold == false)
        let today = try store.ledger(on: day(0))
        #expect(today?.totalPoints == 116)
        #expect(today?.isGold == true)
        #expect(today?.streakAfter == 1)
        // external workout cached for UI
        let cached = try store.workouts(onDay: day(0))
        #expect(cached.count == 1)
        #expect(cached[0].source == "external")
        #expect(cached[0].points == 32)
    }

    @Test func pendingWorkoutSyncsAndCountsToday() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(0): 1_000]
        // a locally recorded, not-yet-synced run
        try store.upsertWorkout(id: UUID(), type: .run, start: day(0).addingTimeInterval(8 * 3600),
                                end: day(0).addingTimeInterval(8 * 3600 + 1500),
                                movingSeconds: 1500, distanceMeters: 5_000, points: 75,
                                routeData: try [RoutePoint(lat: 45.5, lon: -73.6, t: .now, afterGap: false),
                                                RoutePoint(lat: 45.51, lon: -73.6, t: .now, afterGap: false)].encoded(),
                                splitSeconds: [300, 300, 300, 300, 300],
                                source: "runner", hkSynced: false)
        await sync.syncNow()
        #expect(health.savedWorkouts.count == 1)
        #expect(health.savedWorkouts[0].1 == 75)
        #expect(try store.pendingSync().isEmpty)
        // today's ledger includes the pending workout: 10 + 75 = 85
        #expect(try store.ledger(on: day(0))?.totalPoints == 85)
    }

    @Test func failedHealthSaveKeepsPendingAndContinues() async throws {
        let (sync, health, store) = try make()
        health.saveError = NSError(domain: "HK", code: 5,
                                   userInfo: [NSLocalizedDescriptionKey: "not authorized"])
        health.stepsByDay = [day(0): 10_000]
        try store.upsertWorkout(id: UUID(), type: .bike, start: day(0).addingTimeInterval(3600),
                                end: day(0).addingTimeInterval(5400),
                                movingSeconds: 1800, distanceMeters: 10_000, points: 60,
                                routeData: nil, splitSeconds: [],
                                source: "runner", hkSynced: false)
        await sync.syncNow()
        #expect(try store.pendingSync().count == 1)      // still pending
        #expect(sync.lastError != nil)
        // ledger still computed: 100 steps pts + 60 bike = 160
        #expect(try store.ledger(on: day(0))?.totalPoints == 160)
    }

    @Test func storedGoalsPreservedOnResync() async throws {
        let (sync, health, store) = try make(goal: 150)
        // Yesterday was finalized under goal 70.
        try store.upsert([LedgerDay(date: day(-1), steps: 8_000,
                                    breakdown: PointsBreakdown(stepPoints: 80, workoutPoints: 0,
                                                               multiplier: 1.0, total: 80),
                                    goal: 70, isGold: true, streakAfter: 1)])
        health.stepsByDay = [day(-1): 8_000, day(0): 8_000]
        await sync.syncNow()
        let yesterday = try store.ledger(on: day(-1))
        #expect(yesterday?.goalAtThatTime == 70)
        #expect(yesterday?.isGold == true)               // 80 ≥ 70 under its own goal
        #expect(try store.ledger(on: day(0))?.goalAtThatTime == 150)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -20`
Expected: compile failure — `SyncCoordinator` not found.

- [ ] **Step 3: Implement**

`Runner/Core/Store/SyncCoordinator.swift`:

```swift
import Foundation

@MainActor
final class SyncCoordinator {
    static let windowDays = 90

    private let health: HealthStoring
    private let store: DataStore
    private let currentGoal: () -> Int

    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    private(set) var isSyncing = false

    init(health: HealthStoring, store: DataStore, currentGoal: @escaping () -> Int) {
        self.health = health
        self.store = store
        self.currentGoal = currentGoal
    }

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        await retryPendingSaves()

        do {
            let cal = Calendar.current
            let steps = try await health.dailySteps(daysBack: Self.windowDays)
            let hkWorkouts = try await health.workouts(daysBack: Self.windowDays)

            // Cache external workouts for the UI (ours are already cached at save time).
            for w in hkWorkouts where !w.isFromThisApp {
                try store.upsertWorkout(id: w.id, type: w.type, start: w.start,
                                        end: w.start, movingSeconds: 0,
                                        distanceMeters: w.distanceMeters,
                                        points: PointsEngine.workoutPoints(type: w.type,
                                                                           distanceMeters: w.distanceMeters),
                                        routeData: nil, splitSeconds: [],
                                        source: "external", hkSynced: true)
            }

            // Day inputs: HK workouts + local workouts that never reached HK.
            var workoutsByDay = HealthMappers.groupByDay(hkWorkouts, calendar: cal)
            for rec in try store.pendingSync() {
                let day = cal.startOfDay(for: rec.start)
                workoutsByDay[day, default: []]
                    .append(WorkoutSummary(type: rec.type, distanceMeters: rec.distanceMeters))
            }

            let (windowStart, _) = HealthMappers.window(daysBack: Self.windowDays,
                                                        endingAt: Date(), calendar: cal)
            var days: [DayActivity] = []
            for offset in 0..<Self.windowDays {
                let date = cal.date(byAdding: .day, value: offset, to: windowStart)!
                guard date <= Date() else { break }
                days.append(DayActivity(date: date,
                                        steps: steps[date] ?? 0,
                                        workouts: workoutsByDay[date] ?? []))
            }

            let initialStreak = try store.latestLedger(before: windowStart)?.streakAfter ?? 0
            let ledgers = LedgerBuilder.build(days: days,
                                              goalProvider: store.goalProvider(currentGoal: currentGoal()),
                                              initialStreak: initialStreak)
            try store.upsert(ledgers)
            lastSyncAt = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func retryPendingSaves() async {
        guard let pending = try? store.pendingSync(), !pending.isEmpty else { return }
        for rec in pending {
            let workout = RecordedWorkout(type: rec.type, start: rec.start, end: rec.end,
                                          movingSeconds: rec.movingSeconds,
                                          distanceMeters: rec.distanceMeters,
                                          route: rec.routeData.map { [RoutePoint].decode($0) } ?? [],
                                          splitSeconds: rec.splitSeconds)
            do {
                _ = try await health.saveWorkout(workout, points: rec.points)
                try store.upsertWorkout(id: rec.id, type: rec.type, start: rec.start, end: rec.end,
                                        movingSeconds: rec.movingSeconds,
                                        distanceMeters: rec.distanceMeters, points: rec.points,
                                        routeData: rec.routeData, splitSeconds: rec.splitSeconds,
                                        source: rec.source, hkSynced: true)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -5`
Expected: `TEST SUCCEEDED`.

Trace for `backfillBuildsLedgersWithStreaks`: day -2 → 12,000 steps = 120 pts, ×1.0 (initialStreak 0), gold, streak 1. Day -1 → 30 pts under ×1.05 = 32 (rounded 31.5) — wait, verify: 30 × 1.05 = 31.5 → rounds to 32, still `< 100`, not gold, streak 0. Day 0 → (84 + 32) × 1.0 = 116, gold. The test asserts exactly this.

- [ ] **Step 5: Commit**

```bash
git add Runner/Core/Store/SyncCoordinator.swift RunnerTests/FakeHealthStore.swift RunnerTests/SyncCoordinatorTests.swift
git commit -m "feat: sync coordinator — HealthKit to ledger pipeline with pending retry

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 11: App Shell (AppModel, Tab Bar, Settings)

**Files:**
- Create: `Runner/App/AppModel.swift`
- Modify: `Runner/App/RunnerApp.swift` (replace placeholder body)
- Modify: `Runner/App/RootTabView.swift` (replace placeholder entirely)
- Create: `Runner/Features/Settings/SettingsView.swift`
- Test: `RunnerTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `DataStore` (5), `HealthStore`/`HealthStoring` (9), `SyncCoordinator` (10), `WorkoutRecorder`, `SystemLocationProvider` (8), `CheckpointStore`, `SessionCheckpoint` (7), design system (2).
- Produces (relied on by Tasks 12–15):

```swift
@MainActor @Observable final class AppModel {
    let store: DataStore
    let health: HealthStoring
    let sync: SyncCoordinator
    let recorder: WorkoutRecorder
    let checkpoints: CheckpointStore
    var dailyGoal: Int                        // persisted to UserDefaults "dailyGoal", default 100
    var pendingResume: SessionCheckpoint?     // set at launch when a checkpoint exists
    var showRecordSheet: Bool
    static let goalKey = "dailyGoal"
    static func storedGoal() -> Int           // UserDefaults read, default 100, clamped 50...500
    init(store: DataStore, health: HealthStoring, recorder: WorkoutRecorder, checkpoints: CheckpointStore)
    static func live() -> AppModel             // production graph (on-disk store, real HK, GPS)
    func onLaunch() async                      // auth request-if-needed, observer, checkpoint check, sync
    func onForeground() async                  // sync
}

enum AppTab { case today, history, routes }
struct RootTabView: View                       // tabs + raised center Record button
```

Environment wiring: `RootTabView` receives `AppModel` via `.environment(appModel)`; SwiftData views additionally get `.modelContainer(appModel.store.container)`. Tasks 12–15 read `@Environment(AppModel.self)`.

- [ ] **Step 1: Write failing test**

`RunnerTests/AppModelTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

@MainActor
struct AppModelTests {
    private func makeModel() throws -> (AppModel, FakeHealthStore, CheckpointStore) {
        let health = FakeHealthStore()
        let store = try DataStore(inMemory: true)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appmodel-\(UUID().uuidString)")
        let cp = CheckpointStore(directory: dir)
        let recorder = WorkoutRecorder(provider: FakeLocationProvider(), checkpoints: cp)
        return (AppModel(store: store, health: health, recorder: recorder, checkpoints: cp), health, cp)
    }

    @Test func goalPersistsAndClamps() throws {
        UserDefaults.standard.removeObject(forKey: AppModel.goalKey)
        let (model, _, _) = try makeModel()
        #expect(model.dailyGoal == 100)
        model.dailyGoal = 130
        #expect(AppModel.storedGoal() == 130)
        model.dailyGoal = 20            // below floor
        #expect(model.dailyGoal == 50)
        model.dailyGoal = 9_999         // above ceiling
        #expect(model.dailyGoal == 500)
        UserDefaults.standard.removeObject(forKey: AppModel.goalKey)
    }

    @Test func launchDetectsCheckpoint() async throws {
        let (model, _, cp) = try makeModel()
        try cp.save(SessionCheckpoint(activity: .run, startedAt: .now, movingSeconds: 60,
                                      distanceMeters: 300, route: [], splitSeconds: [],
                                      savedAt: .now))
        await model.onLaunch()
        #expect(model.pendingResume != nil)
        #expect(model.pendingResume?.activity == .run)
    }

    @Test func launchSyncsAndObserves() async throws {
        let (model, health, _) = try makeModel()
        health.stepsByDay = [Calendar.current.startOfDay(for: .now): 5_000]
        await model.onLaunch()
        #expect(health.observers.count == 1)
        #expect(try model.store.ledger(on: .now)?.totalPoints == 50)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -20`
Expected: compile failure — `AppModel` not found.

- [ ] **Step 3: Implement AppModel**

`Runner/App/AppModel.swift`:

```swift
import Foundation
import Observation

enum AppTab { case today, history, routes }

@MainActor
@Observable
final class AppModel {
    static let goalKey = "dailyGoal"

    let store: DataStore
    let health: HealthStoring
    let sync: SyncCoordinator
    let recorder: WorkoutRecorder
    let checkpoints: CheckpointStore

    var pendingResume: SessionCheckpoint?
    var showRecordSheet = false
    var selectedTab: AppTab = .today

    var dailyGoal: Int {
        didSet {
            let clamped = min(max(dailyGoal, 50), 500)
            if clamped != dailyGoal { dailyGoal = clamped; return } // didSet re-fires once with valid value
            UserDefaults.standard.set(dailyGoal, forKey: Self.goalKey)
            Task { await sync.syncNow() }
        }
    }

    static func storedGoal() -> Int {
        let raw = UserDefaults.standard.object(forKey: goalKey) as? Int ?? 100
        return min(max(raw, 50), 500)
    }

    init(store: DataStore, health: HealthStoring, recorder: WorkoutRecorder, checkpoints: CheckpointStore) {
        self.store = store
        self.health = health
        self.recorder = recorder
        self.checkpoints = checkpoints
        self.dailyGoal = Self.storedGoal()
        self.sync = SyncCoordinator(health: health, store: store, currentGoal: { Self.storedGoal() })
    }

    static func live() -> AppModel {
        let store: DataStore
        do { store = try DataStore() } catch {
            // Cache is rebuildable; a broken store file is not worth crashing over.
            store = try! DataStore(inMemory: true)
        }
        let checkpoints = CheckpointStore()
        return AppModel(store: store,
                        health: HealthStore(),
                        recorder: WorkoutRecorder(provider: SystemLocationProvider(),
                                                  checkpoints: checkpoints),
                        checkpoints: checkpoints)
    }

    func onLaunch() async {
        if await health.shouldRequestAuthorization() {
            try? await health.requestAuthorization()
        }
        health.startObservingSteps { [weak self] in
            Task { @MainActor [weak self] in await self?.sync.syncNow() }
        }
        pendingResume = checkpoints.load()
        await sync.syncNow()
    }

    func onForeground() async {
        await sync.syncNow()
    }
}
```

- [ ] **Step 4: Implement app entry + tab shell**

`Runner/App/RunnerApp.swift` (replace file):

```swift
import SwiftUI

@main
struct RunnerApp: App {
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(model)
                .modelContainer(model.store.container)
                .preferredColorScheme(.dark)
                .task { await model.onLaunch() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.onForeground() } }
                }
        }
    }
}
```

`Runner/App/RootTabView.swift` (replace file):

```swift
import SwiftUI

struct RootTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottom) {
            Group {
                switch model.selectedTab {
                case .today: TodayView()
                case .history: HistoryView()
                case .routes: RoutesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.rBackground)

            tabBar
        }
        .ignoresSafeArea(.keyboard)
        .fullScreenCover(isPresented: $model.showRecordSheet) {
            RecordView(resumeFrom: model.pendingResume)
                .onDisappear { model.pendingResume = nil }
        }
        .alert("Resume your workout?", isPresented: resumeAlertBinding) {
            Button("Resume") { model.showRecordSheet = true }
            Button("Discard", role: .destructive) {
                model.checkpoints.clear()
                model.pendingResume = nil
            }
        } message: {
            Text("Runner was interrupted mid-workout. Your progress was saved.")
        }
    }

    private var resumeAlertBinding: Binding<Bool> {
        Binding(get: { model.pendingResume != nil && !model.showRecordSheet },
                set: { if !$0 { /* dismissed via buttons */ } })
    }

    private var tabBar: some View {
        HStack {
            tabButton(.today, icon: "bolt.fill", label: String(localized: "Today"))
            tabButton(.history, icon: "chart.bar.fill", label: String(localized: "History"))
            recordButton
            tabButton(.routes, icon: "map.fill", label: String(localized: "Routes"))
            settingsButton
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(
            Rectangle().fill(Color.rBackground.opacity(0.92))
                .overlay(Rectangle().fill(Color.rBorder).frame(height: 1), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func tabButton(_ tab: AppTab, icon: String, label: String) -> some View {
        Button {
            model.selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                Text(label).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(model.selectedTab == tab ? Color.rLime : Color.rTextSecondary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var recordButton: some View {
        Button {
            model.showRecordSheet = true
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.rBackground)
                .frame(width: 58, height: 58)
                .background(
                    Circle().fill(LinearGradient(colors: [.rLime, .rTeal],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .modifier(GlowShadow(color: .rLime))
        }
        .buttonStyle(.plain)
        .offset(y: -18)
        .accessibilityLabel(String(localized: "Record a workout"))
    }

    @State private var showSettings = false
    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "gearshape.fill").font(.system(size: 19, weight: .semibold))
                Text(String(localized: "Settings")).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color.rTextSecondary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}
```

Note: Tasks 12–15 create `TodayView`, `HistoryView`, `RoutesView`, `RecordView`. **For this task to build**, create three one-line stub files that the later tasks replace — `Runner/Features/Today/TodayView.swift`, `Runner/Features/History/HistoryView.swift`, `Runner/Features/Routes/RoutesView.swift`, `Runner/Features/Record/RecordView.swift`:

```swift
import SwiftUI
struct TodayView: View { var body: some View { Text("Today").foregroundStyle(.white) } }
```

```swift
import SwiftUI
struct HistoryView: View { var body: some View { Text("History").foregroundStyle(.white) } }
```

```swift
import SwiftUI
struct RoutesView: View { var body: some View { Text("Routes").foregroundStyle(.white) } }
```

```swift
import SwiftUI
struct RecordView: View {
    let resumeFrom: SessionCheckpoint?
    var body: some View { Text("Record").foregroundStyle(.white) }
}
```

- [ ] **Step 5: Implement SettingsView**

`Runner/Features/Settings/SettingsView.swift`:

```swift
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pendingCount = 0

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section(String(localized: "Daily goal")) {
                    Stepper(value: $model.dailyGoal, in: 50...500, step: 10) {
                        HStack {
                            Text(String(localized: "Goal"))
                            Spacer()
                            Text("\(model.dailyGoal) pts")
                                .foregroundStyle(Color.rLime).bold()
                        }
                    }
                }

                Section(String(localized: "Permissions")) {
                    permissionRow(title: String(localized: "Apple Health"),
                                  ok: model.health.isAvailable && !model.health.writeDenied,
                                  detail: model.health.writeDenied
                                    ? String(localized: "Write access denied — points may be incomplete")
                                    : String(localized: "Connected"))
                    permissionRow(title: String(localized: "Location"),
                                  ok: !model.recorder.authorizationDenied,
                                  detail: model.recorder.authorizationDenied
                                    ? String(localized: "Denied — recording won't work")
                                    : String(localized: "Ready"))
                    if pendingCount > 0 {
                        Label(String(localized: "\(pendingCount) workout(s) waiting to sync to Health"),
                              systemImage: "exclamationmark.arrow.circlepath")
                            .foregroundStyle(Color.rOrange)
                    }
                    Button(String(localized: "Open iOS Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section(String(localized: "How points work")) {
                    ruleRow("👟", String(localized: "1 pt per 100 steps (max 200/day)"))
                    ruleRow("🏃", String(localized: "Run: 15 pts per km"))
                    ruleRow("🚶", String(localized: "Walk: 10 pts per km"))
                    ruleRow("🚴", String(localized: "Bike: 6 pts per km"))
                    ruleRow("🔥", String(localized: "Streak: +5% per gold day, max ×1.5"))
                }

                Section {
                    LabeledContent(String(localized: "Version"), value: "1.0")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.rBackground)
            .navigationTitle(String(localized: "Settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .task { pendingCount = (try? model.store.pendingSync().count) ?? 0 }
        }
        .preferredColorScheme(.dark)
    }

    private func permissionRow(title: String, ok: Bool, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(Color.rTextSecondary)
            }
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color.rTeal : Color.rOrange)
        }
    }

    private func ruleRow(_ emoji: String, _ text: String) -> some View {
        HStack(spacing: 10) { Text(emoji); Text(text).font(.subheadline) }
    }
}
```

- [ ] **Step 6: Run tests, build, and eyeball in the simulator**

```bash
xcodegen generate   # new files added
xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -5
xcrun simctl boot RunnerSim 2>/dev/null; open -a Simulator
xcrun simctl install RunnerSim ~/Library/Developer/Xcode/DerivedData/Runner-*/Build/Products/Debug-iphonesimulator/Runner.app
xcrun simctl launch RunnerSim com.farid.runner
sleep 3 && xcrun simctl io RunnerSim screenshot /tmp/runner-shell.png
```

Expected: `TEST SUCCEEDED`; screenshot shows the dark background, 5-item bottom bar with glowing center play button, stub "Today" text. HealthKit auth prompt may appear on first launch in the simulator — that's correct behavior; tap Allow when testing by hand. (If the `install` glob fails, get the app path from `xcodebuild -showBuildSettings | grep -m1 BUILT_PRODUCTS_DIR`.)

- [ ] **Step 7: Commit**

```bash
git add Runner/App Runner/Features RunnerTests/AppModelTests.swift
git commit -m "feat: app shell — model graph, tab bar with record button, settings

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 12: Today Screen

**Files:**
- Create: `Runner/DesignSystem/Format.swift`
- Create: `Runner/Features/Shared/RouteMapView.swift`
- Create: `Runner/Features/Today/TodayView.swift` (replace stub)
- Test: `RunnerTests/FormatTests.swift`

**Interfaces:**
- Consumes: `AppModel` (11), `DayLedger`/`WorkoutRec` via `@Query` (5), design system (2), `RoutePoint` (7).
- Produces (relied on by Tasks 13, 14, 15):

```swift
enum Format {
    static func duration(_ seconds: Double) -> String       // "5:32" or "1:04:09"
    static func pace(_ secondsPerKm: Double?) -> String      // "5:32 /km" or "—"
    static func km(_ meters: Double) -> String               // "2.10 km" (locale decimal)
}

struct RouteMapView: View {
    init(points: [RoutePoint], interactive: Bool = false)
    // Dark MapKit map, lime glow polyline, dashed gap segments, start ring / end dot.
    static func fittingRegion(for points: [RoutePoint],
                              paddingFactor: Double = 1.4,
                              minSpan: Double = 0.004) -> MKCoordinateRegion
}
```

- [ ] **Step 1: Write failing Format tests**

`RunnerTests/FormatTests.swift`:

```swift
import Testing
@testable import Runner

struct FormatTests {
    @Test func durationFormats() {
        #expect(Format.duration(0) == "0:00")
        #expect(Format.duration(332) == "5:32")
        #expect(Format.duration(3_849) == "1:04:09")
    }

    @Test func paceFormats() {
        #expect(Format.pace(332) == "5:32 /km")
        #expect(Format.pace(nil) == "—")
    }

    @Test func kmUsesTwoDecimals() {
        let s = Format.km(2_100)
        #expect(s.contains("2") && s.contains("10") && s.contains("km"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -20`
Expected: compile failure — `Format` not found.

- [ ] **Step 3: Implement Format**

`Runner/DesignSystem/Format.swift`:

```swift
import Foundation

enum Format {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    static func pace(_ secondsPerKm: Double?) -> String {
        guard let secondsPerKm, secondsPerKm.isFinite, secondsPerKm > 0 else { return "—" }
        return duration(secondsPerKm) + " /km"
    }

    static func km(_ meters: Double) -> String {
        let value = meters / 1000.0
        return value.formatted(.number.precision(.fractionLength(2))) + " km"
    }
}
```

- [ ] **Step 4: Implement RouteMapView**

`Runner/Features/Shared/RouteMapView.swift`:

```swift
import SwiftUI
import MapKit

struct RouteMapView: View {
    let points: [RoutePoint]
    var interactive: Bool = false

    private struct Segment: Identifiable {
        let id: Int
        let coords: [CLLocationCoordinate2D]
        let isGapConnector: Bool
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        var current: [CLLocationCoordinate2D] = []
        var id = 0
        for point in points {
            let coord = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
            if point.afterGap, let last = current.last {
                out.append(Segment(id: id, coords: current, isGapConnector: false)); id += 1
                out.append(Segment(id: id, coords: [last, coord], isGapConnector: true)); id += 1
                current = [coord]
            } else {
                current.append(coord)
            }
        }
        if current.count >= 2 { out.append(Segment(id: id, coords: current, isGapConnector: false)) }
        return out
    }

    /// Region fitting `points` with padding — shared by every map screen (Routes reuses it).
    static func fittingRegion(for points: [RoutePoint],
                              paddingFactor: Double = 1.4,
                              minSpan: Double = 0.004) -> MKCoordinateRegion {
        guard let first = points.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 45.5, longitude: -73.6),
                                      span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        }
        var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
        for p in points {
            minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
            minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * paddingFactor, minSpan),
                                   longitudeDelta: max((maxLon - minLon) * paddingFactor, minSpan)))
    }

    private var region: MKCoordinateRegion { Self.fittingRegion(for: points) }

    var body: some View {
        Map(initialPosition: .region(region), interactionModes: interactive ? .all : []) {
            ForEach(segments) { segment in
                if segment.isGapConnector {
                    MapPolyline(coordinates: segment.coords)
                        .stroke(Color.rLime.opacity(0.4),
                                style: StrokeStyle(lineWidth: 2.5, dash: [5, 7]))
                } else {
                    MapPolyline(coordinates: segment.coords)
                        .stroke(Color.rLime.opacity(0.25), lineWidth: 9)
                    MapPolyline(coordinates: segment.coords)
                        .stroke(Color.rLime,
                                style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                }
            }
            if let first = points.first {
                Annotation("", coordinate: .init(latitude: first.lat, longitude: first.lon)) {
                    Circle().stroke(Color.rLime, lineWidth: 3)
                        .background(Circle().fill(Color.rBackground))
                        .frame(width: 12, height: 12)
                }
            }
            if points.count > 1, let last = points.last {
                Annotation("", coordinate: .init(latitude: last.lat, longitude: last.lon)) {
                    Circle().fill(Color.rLime).frame(width: 11, height: 11)
                        .modifier(GlowShadow(color: .rLime))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }
}
```

- [ ] **Step 5: Implement TodayView (replace stub)**

`Runner/Features/Today/TodayView.swift`:

```swift
import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \DayLedger.date, order: .reverse) private var ledgers: [DayLedger]
    @Query(sort: \WorkoutRec.start, order: .reverse) private var workouts: [WorkoutRec]
    @State private var celebrate = false

    private var today: DayLedger? {
        ledgers.first { Calendar.current.isDateInToday($0.date) }
    }
    private var todayWorkouts: [WorkoutRec] {
        workouts.filter { Calendar.current.isDateInToday($0.start) }
    }
    private var streakEnteringToday: Int {
        ledgers.first { !Calendar.current.isDateInToday($0.date) }?.streakAfter ?? 0
    }
    private var latestRoute: [RoutePoint] {
        guard let data = todayWorkouts.first(where: { $0.routeData != nil })?.routeData else { return [] }
        return [RoutePoint].decode(data)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                pointsBlock
                breakdown
                if !latestRoute.isEmpty { miniMap }
                if let error = model.sync.lastError {
                    SurfaceCard {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(Color.rOrange)
                    }
                }
                Spacer(minLength: 90) // clear the tab bar
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        .background(Color.rBackground)
        .overlay { if celebrate { CelebrationBurst() } }
        .onChange(of: today?.isGold ?? false) { was, isNow in
            if !was && isNow {
                celebrate = true
                Task { try? await Task.sleep(for: .seconds(1.6)); celebrate = false }
            }
        }
        .refreshable { await model.sync.syncNow() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            MicroLabel(text: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            if streakEnteringToday > 0 || (today?.isGold ?? false) {
                let streak = today?.isGold == true ? (today?.streakAfter ?? 0) : streakEnteringToday
                Text("🔥 \(streak)-day streak · ×\((today?.multiplier ?? 1).formatted(.number.precision(.fractionLength(2))))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.rOrange)
            }
        }
        .padding(.top, 10)
    }

    private var pointsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                GlowNumber(value: today?.totalPoints ?? 0, unitLabel: "PTS")
                Spacer()
                if today?.isGold == true {
                    Text(String(localized: "GOLD DAY"))
                        .font(.system(size: 11, weight: .black))
                        .tracking(1.5)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.rLime.opacity(0.15)))
                        .overlay(Capsule().stroke(Color.rLime, lineWidth: 1))
                        .foregroundStyle(Color.rLime)
                }
            }
            GoalBar(points: today?.totalPoints ?? 0, goal: model.dailyGoal)
            Text(String(localized: "Goal: \(model.dailyGoal) pts"))
                .font(.caption).foregroundStyle(Color.rTextSecondary)
        }
    }

    private var breakdown: some View {
        SurfaceCard {
            VStack(spacing: 0) {
                breakdownRow(emoji: "👟",
                             label: String(localized: "\((today?.steps ?? 0).formatted()) steps"),
                             value: today?.stepPoints ?? 0, accent: .rLime)
                ForEach(todayWorkouts) { workout in
                    Divider().overlay(Color.rBorder)
                    breakdownRow(emoji: workout.type.emoji,
                                 label: "\(workout.type.localizedName) · \(Format.km(workout.distanceMeters))",
                                 value: workout.points, accent: workout.type.accent)
                }
                if let today, today.multiplier > 1.0 {
                    Divider().overlay(Color.rBorder)
                    HStack {
                        Text("🔥 \(String(localized: "Streak bonus"))")
                            .font(.system(size: 14))
                        Spacer()
                        Text("×\(today.multiplier.formatted(.number.precision(.fractionLength(2))))")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.rOrange)
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func breakdownRow(emoji: String, label: String, value: Int, accent: Color) -> some View {
        HStack {
            Text(emoji)
            Text(label).font(.system(size: 14)).foregroundStyle(.white)
            Spacer()
            Text("+\(value)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
        }
        .padding(.vertical, 10)
    }

    private var miniMap: some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: String(localized: "Latest parcours"))
            RouteMapView(points: latestRoute)
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.rBorder, lineWidth: 1))
        }
    }
}

struct CelebrationBurst: View {
    @State private var scale: CGFloat = 0.4
    @State private var opacity: Double = 0.9

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color.rLime.opacity(0.5), .clear],
                                 center: .center, startRadius: 10, endRadius: 240))
            .scaleEffect(scale)
            .opacity(opacity)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 1.4)) { scale = 2.4; opacity = 0 }
                Haptics.goalReached()
            }
    }
}

/// Task 17 upgrades this to real haptic feedback; keep the seam now so call
/// sites don't change.
enum Haptics {
    static func goalReached() {}
    static func kmSplit() {}
}
```

- [ ] **Step 6: Run tests, build, verify in simulator with seeded data**

```bash
xcodegen generate
xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -5
```

Expected: `TEST SUCCEEDED`. Then launch in the simulator (same install/launch/screenshot commands as Task 11 Step 6). The simulator has no Health data, so verify: big `0 PTS` glow number renders, goal bar empty, breakdown card shows `0 steps +0`. UI structure and styling are what's being checked here — data flows are already unit-tested.

- [ ] **Step 7: Commit**

```bash
git add Runner/DesignSystem/Format.swift Runner/Features/Shared Runner/Features/Today RunnerTests/FormatTests.swift
git commit -m "feat: Today screen — glowing points, breakdown, streak, mini route map

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 13: Record Screen (live HUD, summary, resume)

**Files:**
- Create: `Runner/Features/Record/SlideToFinish.swift`
- Create: `Runner/Features/Record/WorkoutSummaryView.swift`
- Modify: `Runner/Features/Record/RecordView.swift` (replace stub entirely)
- Test: manual simulator route (commands below) — the recording logic itself was fully tested in Task 8

**Interfaces:**
- Consumes: `WorkoutRecorder`, `RecordedWorkout`, `SessionCheckpoint` (8), `PointsEngine` (3), `AppModel` (11), `RouteMapView`, `Format`, `Haptics` (12), `HealthStoring.saveWorkout` (9), `DataStore.upsertWorkout` (5).
- Produces: `RecordView(resumeFrom: SessionCheckpoint?)` — presented by RootTabView (11). Save path contract: HK save success → `upsertWorkout(id: hkUUID, …, source: "runner", hkSynced: true)`; HK save failure → `upsertWorkout(id: UUID(), …, hkSynced: false)` (pending, retried by SyncCoordinator); both paths then `await model.sync.syncNow()`.

- [ ] **Step 1: Implement SlideToFinish**

`Runner/Features/Record/SlideToFinish.swift`:

```swift
import SwiftUI

struct SlideToFinish: View {
    let onFinish: () -> Void
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.width - 62
            ZStack(alignment: .leading) {
                Capsule().fill(Color.rSurface)
                    .overlay(Capsule().stroke(Color.rBorder, lineWidth: 1))
                Text(String(localized: "Slide to finish"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.rTextSecondary)
                    .frame(maxWidth: .infinity)
                    .opacity(1.0 - Double(offset / max(travel, 1)) * 1.6)
                Circle()
                    .fill(Color.rLime)
                    .frame(width: 50, height: 50)
                    .overlay(Image(systemName: "flag.checkered")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.rBackground))
                    .offset(x: offset + 6)
                    .gesture(
                        DragGesture()
                            .onChanged { offset = min(max(0, $0.translation.width), travel) }
                            .onEnded { _ in
                                if offset > travel * 0.85 {
                                    onFinish()
                                } else {
                                    withAnimation(.spring(duration: 0.3)) { offset = 0 }
                                }
                            }
                    )
            }
        }
        .frame(height: 62)
    }
}
```

- [ ] **Step 2: Implement WorkoutSummaryView**

`Runner/Features/Record/WorkoutSummaryView.swift`:

```swift
import SwiftUI

struct WorkoutSummaryView: View {
    let workout: RecordedWorkout
    let onSave: () -> Void
    let onDiscard: () -> Void

    private var points: Int {
        PointsEngine.workoutPoints(type: workout.type, distanceMeters: workout.distanceMeters)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("\(workout.type.emoji) \(workout.type.localizedName)")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 18)

            RouteMapView(points: workout.route, interactive: true)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.rBorder, lineWidth: 1))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("+\(points)")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.rLime)
                    .modifier(GlowShadow(color: .rLime))
                Text("PTS").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.rLime)
            }

            HStack(spacing: 10) {
                stat(String(localized: "Distance"), Format.km(workout.distanceMeters))
                stat(String(localized: "Time"), Format.duration(workout.movingSeconds))
                stat(String(localized: "Pace"),
                     Format.pace(workout.distanceMeters >= 100
                                 ? workout.movingSeconds / (workout.distanceMeters / 1000)
                                 : nil))
            }

            if !workout.splitSeconds.isEmpty {
                SurfaceCard {
                    VStack(spacing: 6) {
                        ForEach(Array(workout.splitSeconds.enumerated()), id: \.offset) { index, seconds in
                            HStack {
                                Text(String(localized: "Km \(index + 1)"))
                                    .font(.system(size: 13)).foregroundStyle(Color.rTextSecondary)
                                Spacer()
                                Text(Format.duration(seconds))
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
            }

            Spacer()

            VStack(spacing: 10) {
                Button(action: onSave) {
                    Text(String(localized: "Save workout"))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rBackground)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(Capsule().fill(Color.rLime))
                }
                Button(action: onDiscard) {
                    Text(String(localized: "Discard"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.rTextSecondary)
                }
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 18)
        .background(Color.rBackground)
        .interactiveDismissDisabled()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 4) {
                MicroLabel(text: label)
                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }
}
```

- [ ] **Step 3: Implement RecordView (replace stub)**

`Runner/Features/Record/RecordView.swift`:

```swift
import SwiftUI
import MapKit

struct RecordView: View {
    let resumeFrom: SessionCheckpoint?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedActivity: ActivityType = .run
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var finished: RecordedWorkout?
    @State private var saveFailedMessage: String?

    private var recorder: WorkoutRecorder { model.recorder }
    private var isActive: Bool { recorder.state != .idle }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                UserAnnotation()
                if recorder.route.count >= 2 {
                    MapPolyline(coordinates: recorder.route.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    })
                    .stroke(Color.rLime,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .ignoresSafeArea()

            if recorder.authorizationDenied {
                deniedOverlay
            } else if isActive {
                activeHUD
            } else {
                setupPanel
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            recorder.requestPermission()
            recorder.onKmSplit = { _ in Haptics.kmSplit() }
            if let resumeFrom {
                recorder.start(activity: resumeFrom.activity, resumeFrom: resumeFrom)
            }
        }
        .sheet(item: $finished) { workout in
            WorkoutSummaryView(workout: workout,
                               onSave: { Task { await save(workout) } },
                               onDiscard: { finished = nil; dismiss() })
        }
        .alert(String(localized: "Saved locally"), isPresented: .init(
            get: { saveFailedMessage != nil },
            set: { if !$0 { saveFailedMessage = nil; dismiss() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            let detail = saveFailedMessage ?? ""
            Text(String(localized: "Apple Health refused the save (\(detail)). The workout is kept in Runner and will retry automatically."))
        }
    }

    // MARK: Setup

    private var setupPanel: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                ForEach(ActivityType.allCases, id: \.self) { activity in
                    Button {
                        selectedActivity = activity
                    } label: {
                        VStack(spacing: 6) {
                            Text(activity.emoji).font(.system(size: 26))
                            Text(activity.localizedName)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 14)
                            .fill(selectedActivity == activity ? activity.accent.opacity(0.18) : Color.rSurface))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(selectedActivity == activity ? activity.accent : Color.rBorder,
                                    lineWidth: selectedActivity == activity ? 2 : 1))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                recorder.start(activity: selectedActivity)
            } label: {
                Text(String(localized: "GO"))
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(Color.rBackground)
                    .frame(maxWidth: .infinity).frame(height: 62)
                    .background(Capsule().fill(
                        LinearGradient(colors: [.rLime, .rTeal],
                                       startPoint: .leading, endPoint: .trailing)))
                    .modifier(GlowShadow(color: .rLime))
            }
            .buttonStyle(.plain)

            Button(String(localized: "Cancel")) { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.rTextSecondary)
        }
        .padding(18)
        .background(panelBackground)
    }

    // MARK: Active HUD

    private var activeHUD: some View {
        VStack(spacing: 14) {
            if recorder.state == .autoPaused {
                Label(String(localized: "Auto-paused"), systemImage: "pause.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.rOrange)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.rOrange.opacity(0.15)))
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(recorder.livePoints)")
                    .font(.system(size: 54, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.rLime)
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.4), value: recorder.livePoints)
                    .modifier(GlowShadow(color: .rLime))
                Text("PTS").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.rLime)
            }

            HStack(spacing: 10) {
                hudStat(String(localized: "Time"), Format.duration(recorder.movingSeconds))
                hudStat(String(localized: "Distance"), Format.km(recorder.distanceMeters))
                hudStat(String(localized: "Pace"), Format.pace(recorder.paceSecondsPerKm))
            }

            HStack(spacing: 12) {
                Button {
                    if recorder.state == .manuallyPaused {
                        recorder.resumeManually()
                    } else {
                        recorder.pauseManually()
                    }
                } label: {
                    Image(systemName: recorder.state == .manuallyPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.rSurface))
                        .overlay(Circle().stroke(Color.rBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                SlideToFinish {
                    finished = recorder.finish()
                }
            }
        }
        .padding(18)
        .background(panelBackground)
    }

    private var deniedOverlay: some View {
        VStack(spacing: 12) {
            Text("📍").font(.system(size: 40))
            Text(String(localized: "Runner needs location access to draw your parcours."))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Button(String(localized: "Open iOS Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Color.rLime)
            Button(String(localized: "Cancel")) { dismiss() }
                .font(.system(size: 14))
                .foregroundStyle(Color.rTextSecondary)
        }
        .padding(24)
        .background(panelBackground)
        .padding(.bottom, 40)
    }

    private func hudStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            MicroLabel(text: label)
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.rSurface.opacity(0.85)))
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(Color.rBackground.opacity(0.92))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.rBorder, lineWidth: 1))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .ignoresSafeArea(edges: .bottom)
    }

    // MARK: Save

    private func save(_ workout: RecordedWorkout) async {
        let points = PointsEngine.workoutPoints(type: workout.type,
                                                distanceMeters: workout.distanceMeters)
        let routeData = try? workout.route.encoded()
        do {
            let hkID = try await model.health.saveWorkout(workout, points: points)
            try? model.store.upsertWorkout(id: hkID, type: workout.type,
                                           start: workout.start, end: workout.end,
                                           movingSeconds: workout.movingSeconds,
                                           distanceMeters: workout.distanceMeters, points: points,
                                           routeData: routeData, splitSeconds: workout.splitSeconds,
                                           source: "runner", hkSynced: true)
            await model.sync.syncNow()
            finished = nil
            dismiss()
        } catch {
            try? model.store.upsertWorkout(id: UUID(), type: workout.type,
                                           start: workout.start, end: workout.end,
                                           movingSeconds: workout.movingSeconds,
                                           distanceMeters: workout.distanceMeters, points: points,
                                           routeData: routeData, splitSeconds: workout.splitSeconds,
                                           source: "runner", hkSynced: false)
            await model.sync.syncNow()
            finished = nil
            saveFailedMessage = error.localizedDescription
        }
    }
}

extension RecordedWorkout: Identifiable {
    var id: Date { start }
}
```

- [ ] **Step 4: Build, test, and drive a simulated ride**

```bash
xcodegen generate
xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -5
# install + launch (same as Task 11 Step 6), then feed the simulator a moving location:
xcrun simctl location RunnerSim start --speed=3.0 --interval=1 "45.5017,-73.5673" "45.5090,-73.5620" "45.5130,-73.5700"
```

Manual verification in the Simulator window: open Record (▶), pick 🏃, tap GO, watch time/distance/pace/points tick and the lime line grow on the map; `xcrun simctl location RunnerSim clear` freezes movement → auto-pause chip appears after ~10 s; restart movement, slide-to-finish → summary shows route, stats, splits (if ≥1 km), points; tap Save — in the simulator the HealthKit save succeeds if Health permissions were granted at first launch (grant them), and Today now lists the workout. If `simctl location` rejects the flags on this Xcode version, run `xcrun simctl location` for usage — the subcommand syntax has shifted between releases; `start` with waypoints and `--speed` is the intent.

- [ ] **Step 5: Commit**

```bash
git add Runner/Features/Record
git commit -m "feat: record screen — live points HUD, slide-to-finish, summary, resume

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 14: History Screen

**Files:**
- Create: `Runner/Features/History/HistoryMath.swift`
- Create: `Runner/Features/History/HeatmapView.swift`
- Create: `Runner/Features/History/WorkoutDetailView.swift`
- Modify: `Runner/Features/History/HistoryView.swift` (replace stub entirely)
- Test: `RunnerTests/HistoryMathTests.swift`

**Interfaces:**
- Consumes: `DayLedger`/`WorkoutRec` via `@Query` (5), `AppModel` (11), `RouteMapView`/`Format` (12), design system (2).
- Produces (Task 15 reuses `WorkoutDetailView`):

```swift
struct DaySnapshot: Equatable {
    let date: Date
    let points: Int
    let isGold: Bool
}

enum HistoryMath {
    // Columns oldest→newest; each column has 7 slots Monday→Sunday.
    // Days without data become points 0; slots after `today` are nil.
    static func heatmapWeeks(days: [DaySnapshot], today: Date, weekCount: Int,
                             calendar: Calendar) -> [[DaySnapshot?]]
    static func intensity(points: Int, goal: Int) -> Double   // 0 for 0 pts, else 0.25 + 0.75×min(p/goal, 1)
    // Continuous series of the last N days ending at `endingAt`, zero-filled.
    static func dailySeries(days: [DaySnapshot], lastN: Int, endingAt: Date,
                            calendar: Calendar) -> [DaySnapshot]
}

struct WorkoutDetailView: View { init(workout: WorkoutRec) }
```

- [ ] **Step 1: Write failing tests**

`RunnerTests/HistoryMathTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

struct HistoryMathTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday
        return c
    }
    // 2026-07-01 is a Wednesday.
    private let wednesday = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2026, month: 7, day: 1))!

    private func d(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: wednesday)! }

    @Test func heatmapShapeAndAlignment() {
        let days = [DaySnapshot(date: d(0), points: 120, isGold: true)]
        let weeks = HistoryMath.heatmapWeeks(days: days, today: d(0), weekCount: 2, calendar: cal)
        #expect(weeks.count == 2)
        #expect(weeks.allSatisfy { $0.count == 7 })
        // Wednesday of the current week = index 2 in the last column
        #expect(weeks[1][2]?.points == 120)
        // Thursday..Sunday of the current week are in the future → nil
        #expect(weeks[1][3] == nil)
        #expect(weeks[1][6] == nil)
        // A data-less past day is zero, not nil
        #expect(weeks[0][0]?.points == 0)
    }

    @Test func intensityCurve() {
        #expect(HistoryMath.intensity(points: 0, goal: 100) == 0)
        #expect(abs(HistoryMath.intensity(points: 50, goal: 100) - 0.625) < 0.0001)
        #expect(HistoryMath.intensity(points: 100, goal: 100) == 1.0)
        #expect(HistoryMath.intensity(points: 400, goal: 100) == 1.0)
        #expect(HistoryMath.intensity(points: 10, goal: 0) == 1.0) // degenerate goal → full
    }

    @Test func dailySeriesZeroFills() {
        let days = [DaySnapshot(date: d(-1), points: 80, isGold: false)]
        let series = HistoryMath.dailySeries(days: days, lastN: 7, endingAt: d(0), calendar: cal)
        #expect(series.count == 7)
        #expect(series.last?.points == 0)          // today: no data
        #expect(series[5].points == 80)            // yesterday
        #expect(series.first?.date == d(-6))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -20`
Expected: compile failure — `HistoryMath` not found.

- [ ] **Step 3: Implement HistoryMath**

`Runner/Features/History/HistoryMath.swift`:

```swift
import Foundation

struct DaySnapshot: Equatable {
    let date: Date
    let points: Int
    let isGold: Bool
}

enum HistoryMath {
    static func heatmapWeeks(days: [DaySnapshot], today: Date, weekCount: Int,
                             calendar: Calendar) -> [[DaySnapshot?]] {
        let todayStart = calendar.startOfDay(for: today)
        let byDate = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.date), $0) })

        // Monday of the current week (weekday: 1=Sun, 2=Mon, ...).
        let weekday = calendar.component(.weekday, from: todayStart)
        let daysSinceMonday = (weekday + 5) % 7
        let currentMonday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: todayStart)!
        let firstMonday = calendar.date(byAdding: .day, value: -7 * (weekCount - 1), to: currentMonday)!

        var weeks: [[DaySnapshot?]] = []
        for w in 0..<weekCount {
            var column: [DaySnapshot?] = []
            for dow in 0..<7 {
                let date = calendar.date(byAdding: .day, value: w * 7 + dow, to: firstMonday)!
                if date > todayStart {
                    column.append(nil)
                } else {
                    column.append(byDate[date] ?? DaySnapshot(date: date, points: 0, isGold: false))
                }
            }
            weeks.append(column)
        }
        return weeks
    }

    static func intensity(points: Int, goal: Int) -> Double {
        guard points > 0 else { return 0 }
        guard goal > 0 else { return 1 }
        return 0.25 + 0.75 * min(Double(points) / Double(goal), 1.0)
    }

    static func dailySeries(days: [DaySnapshot], lastN: Int, endingAt: Date,
                            calendar: Calendar) -> [DaySnapshot] {
        let end = calendar.startOfDay(for: endingAt)
        let byDate = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.date), $0) })
        return (0..<lastN).reversed().map { back in
            let date = calendar.date(byAdding: .day, value: -back, to: end)!
            return byDate[date] ?? DaySnapshot(date: date, points: 0, isGold: false)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -5`
Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Implement the views**

`Runner/Features/History/HeatmapView.swift`:

```swift
import SwiftUI

struct HeatmapView: View {
    let weeks: [[DaySnapshot?]]
    let goal: Int

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(weeks.indices, id: \.self) { w in
                VStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { d in
                        cell(weeks[w][d])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ snapshot: DaySnapshot?) -> some View {
        if let snapshot {
            RoundedRectangle(cornerRadius: 3)
                .fill(snapshot.points > 0
                      ? Color.rLime.opacity(HistoryMath.intensity(points: snapshot.points, goal: goal))
                      : Color.rSurface)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(snapshot.isGold ? Color.rLime : Color.rBorder,
                            lineWidth: snapshot.isGold ? 1.5 : 0.5))
                .frame(width: 16, height: 16)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.clear)
                .frame(width: 16, height: 16)
        }
    }
}
```

`Runner/Features/History/WorkoutDetailView.swift`:

```swift
import SwiftUI

struct WorkoutDetailView: View {
    let workout: WorkoutRec

    private var route: [RoutePoint] {
        workout.routeData.map { [RoutePoint].decode($0) } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if route.count >= 2 {
                    RouteMapView(points: route, interactive: true)
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.rBorder, lineWidth: 1))
                } else {
                    SurfaceCard {
                        Label(String(localized: "No route for this workout (imported from Health)"),
                              systemImage: "map")
                            .font(.caption).foregroundStyle(Color.rTextSecondary)
                    }
                }

                HStack(spacing: 10) {
                    detailStat(String(localized: "Points"), "+\(workout.points)", accent: .rLime)
                    detailStat(String(localized: "Distance"), Format.km(workout.distanceMeters), accent: .white)
                    detailStat(String(localized: "Time"),
                               workout.movingSeconds > 0 ? Format.duration(workout.movingSeconds) : "—",
                               accent: .white)
                }

                if !workout.splitSeconds.isEmpty {
                    SurfaceCard {
                        VStack(spacing: 6) {
                            MicroLabel(text: String(localized: "Splits"))
                            ForEach(Array(workout.splitSeconds.enumerated()), id: \.offset) { index, seconds in
                                HStack {
                                    Text(String(localized: "Km \(index + 1)"))
                                        .font(.system(size: 13)).foregroundStyle(Color.rTextSecondary)
                                    Spacer()
                                    Text(Format.duration(seconds))
                                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 90)
            }
            .padding(18)
        }
        .background(Color.rBackground)
        .navigationTitle("\(workout.type.emoji) \(workout.start.formatted(date: .abbreviated, time: .shortened))")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailStat(_ label: String, _ value: String, accent: Color) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 4) {
                MicroLabel(text: label)
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }
}
```

`Runner/Features/History/HistoryView.swift` (replace stub):

```swift
import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \DayLedger.date, order: .forward) private var ledgers: [DayLedger]
    @Query(sort: \WorkoutRec.start, order: .reverse) private var workouts: [WorkoutRec]
    @State private var chartRange = 7

    private var snapshots: [DaySnapshot] {
        ledgers.map { DaySnapshot(date: $0.date, points: $0.totalPoints, isGold: $0.isGold) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MicroLabel(text: String(localized: "Last 13 weeks"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HeatmapView(weeks: HistoryMath.heatmapWeeks(days: snapshots, today: .now,
                                                                    weekCount: 13,
                                                                    calendar: .current),
                                    goal: model.dailyGoal)
                    }

                    chartSection
                    recordsSection
                    workoutsSection
                    Spacer(minLength: 90)
                }
                .padding(.horizontal, 18)
            }
            .background(Color.rBackground)
            .navigationTitle(String(localized: "History"))
            .navigationDestination(for: WorkoutRec.self) { WorkoutDetailView(workout: $0) }
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(String(localized: "Range"), selection: $chartRange) {
                Text(String(localized: "Week")).tag(7)
                Text(String(localized: "Month")).tag(30)
            }
            .pickerStyle(.segmented)

            Chart {
                ForEach(HistoryMath.dailySeries(days: snapshots, lastN: chartRange,
                                                endingAt: .now, calendar: .current),
                        id: \.date) { day in
                    BarMark(x: .value("Day", day.date, unit: .day),
                            y: .value("Points", day.points))
                        .foregroundStyle(day.isGold ? Color.rLime : Color.rLime.opacity(0.35))
                        .cornerRadius(3)
                }
                RuleMark(y: .value("Goal", model.dailyGoal))
                    .foregroundStyle(Color.rOrange.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .frame(height: 180)
            .chartYAxis { AxisMarks(position: .trailing) }
        }
    }

    private var recordsSection: some View {
        SurfaceCard {
            VStack(spacing: 8) {
                MicroLabel(text: String(localized: "Records"))
                recordRow("🏆", String(localized: "Best day"),
                          "\(ledgers.map(\.totalPoints).max() ?? 0) pts")
                recordRow("🔥", String(localized: "Best streak"),
                          String(localized: "\(ledgers.map(\.streakAfter).max() ?? 0) days"))
                recordRow("🏃", String(localized: "Longest run"),
                          Format.km(workouts.filter { $0.type == .run }.map(\.distanceMeters).max() ?? 0))
                recordRow("🚴", String(localized: "Longest ride"),
                          Format.km(workouts.filter { $0.type == .bike }.map(\.distanceMeters).max() ?? 0))
            }
        }
    }

    private func recordRow(_ emoji: String, _ label: String, _ value: String) -> some View {
        HStack {
            Text(emoji)
            Text(label).font(.system(size: 14)).foregroundStyle(.white)
            Spacer()
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rLime)
        }
    }

    private var workoutsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: String(localized: "Workouts"))
            if workouts.isEmpty {
                SurfaceCard {
                    Text(String(localized: "No workouts yet — hit the ▶ button!"))
                        .font(.subheadline).foregroundStyle(Color.rTextSecondary)
                }
            }
            ForEach(workouts) { workout in
                NavigationLink(value: workout) {
                    SurfaceCard {
                        HStack {
                            Text(workout.type.emoji).font(.system(size: 22))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(workout.type.localizedName) · \(Format.km(workout.distanceMeters))")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(workout.start.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(Color.rTextSecondary)
                            }
                            Spacer()
                            Text("+\(workout.points)")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(workout.type.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
```

- [ ] **Step 6: Build + test + simulator eyeball**

```bash
xcodegen generate
xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -5
```

Expected: `TEST SUCCEEDED`. Reinstall in the simulator; History tab shows an (empty) heatmap grid, segmented week/month chart with the dashed goal line, records card with zeros, empty-state workouts row. If a workout was recorded in Task 13's verification, it appears in the list and opens the detail with its route.

- [ ] **Step 7: Commit**

```bash
git add Runner/Features/History RunnerTests/HistoryMathTests.swift
git commit -m "feat: history — points heatmap, charts with goal line, records, workout detail

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 15: Routes Screen

**Files:**
- Create: `Runner/Features/Routes/RouteHitTest.swift`
- Modify: `Runner/Features/Routes/RoutesView.swift` (replace stub entirely)
- Test: `RunnerTests/RouteHitTestTests.swift`

**Interfaces:**
- Consumes: `WorkoutRec` via `@Query` (5), `RoutePoint` (7), `WorkoutDetailView` (14), design system (2).
- Produces: the Routes tab. Pure helper:

```swift
enum RouteHitTest {
    /// Nearest workout whose route passes within maxMeters of the tap; nil otherwise.
    static func nearestWorkout(toLat lat: Double, lon: Double,
                               routes: [(id: UUID, points: [RoutePoint])],
                               maxMeters: Double) -> UUID?
}
```

- [ ] **Step 1: Write failing tests**

`RunnerTests/RouteHitTestTests.swift`:

```swift
import Testing
import Foundation
@testable import Runner

struct RouteHitTestTests {
    private func point(x: Double, y: Double) -> RoutePoint {
        RoutePoint(lat: 45.5 + y / 111_320.0,
                   lon: -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180)),
                   t: .now, afterGap: false)
    }

    @Test func findsNearestRouteWithinThreshold() {
        let a = UUID(), b = UUID()
        let routes = [
            (id: a, points: [point(x: 0, y: 0), point(x: 100, y: 0)]),
            (id: b, points: [point(x: 0, y: 500), point(x: 100, y: 500)]),
        ]
        // tap 30 m from route A, 470 m from route B
        let tap = point(x: 50, y: 30)
        #expect(RouteHitTest.nearestWorkout(toLat: tap.lat, lon: tap.lon,
                                            routes: routes, maxMeters: 100) == a)
    }

    @Test func returnsNilWhenNothingClose() {
        let routes = [(id: UUID(), points: [point(x: 0, y: 0), point(x: 100, y: 0)])]
        let tap = point(x: 50, y: 900)
        #expect(RouteHitTest.nearestWorkout(toLat: tap.lat, lon: tap.lon,
                                            routes: routes, maxMeters: 100) == nil)
    }

    @Test func emptyRoutesReturnsNil() {
        #expect(RouteHitTest.nearestWorkout(toLat: 45.5, lon: -73.6, routes: [], maxMeters: 100) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -20`
Expected: compile failure — `RouteHitTest` not found.

- [ ] **Step 3: Implement**

`Runner/Features/Routes/RouteHitTest.swift`:

```swift
import Foundation
import CoreLocation

enum RouteHitTest {
    static func nearestWorkout(toLat lat: Double, lon: Double,
                               routes: [(id: UUID, points: [RoutePoint])],
                               maxMeters: Double) -> UUID? {
        let tap = CLLocation(latitude: lat, longitude: lon)
        var best: (id: UUID, distance: Double)?
        for route in routes {
            for point in route.points {
                let d = tap.distance(from: CLLocation(latitude: point.lat, longitude: point.lon))
                if d <= maxMeters && d < (best?.distance ?? .infinity) {
                    best = (route.id, d)
                }
            }
        }
        return best?.id
    }
}
```

`Runner/Features/Routes/RoutesView.swift` (replace stub):

```swift
import SwiftUI
import SwiftData
import MapKit

struct RoutesView: View {
    @Query(sort: \WorkoutRec.start, order: .reverse) private var workouts: [WorkoutRec]
    @State private var filter: ActivityType?
    @State private var selected: WorkoutRec?

    private var routed: [(rec: WorkoutRec, points: [RoutePoint])] {
        workouts.compactMap { rec in
            guard filter == nil || rec.type == filter,
                  let data = rec.routeData else { return nil }
            let points = [RoutePoint].decode(data)
            return points.count >= 2 ? (rec, points) : nil
        }
    }

    private var region: MKCoordinateRegion {
        RouteMapView.fittingRegion(for: routed.flatMap(\.points),
                                   paddingFactor: 1.3, minSpan: 0.01)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                MapReader { proxy in
                    Map(initialPosition: .region(region)) {
                        ForEach(routed, id: \.rec.id) { item in
                            MapPolyline(coordinates: item.points.map {
                                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                            })
                            .stroke(item.rec.type.accent.opacity(0.9),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        }
                    }
                    .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                    .onTapGesture { screenPoint in
                        guard let coord = proxy.convert(screenPoint, from: .local) else { return }
                        let hit = RouteHitTest.nearestWorkout(
                            toLat: coord.latitude, lon: coord.longitude,
                            routes: routed.map { ($0.rec.id, $0.points) },
                            maxMeters: 120)
                        selected = routed.first { $0.rec.id == hit }?.rec
                    }
                }
                .ignoresSafeArea(edges: .top)

                filterChips
            }
            .background(Color.rBackground)
            .navigationDestination(item: $selected) { WorkoutDetailView(workout: $0) }
            .overlay(alignment: .bottom) {
                if routed.isEmpty {
                    SurfaceCard {
                        Text(String(localized: "No routes yet — record a run, walk or ride and your city starts glowing."))
                            .font(.subheadline).foregroundStyle(Color.rTextSecondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 100)
                }
            }
        }
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            chip(nil, label: String(localized: "All"))
            ForEach(ActivityType.allCases, id: \.self) { type in
                chip(type, label: "\(type.emoji) \(type.localizedName)")
            }
        }
        .padding(.top, 8)
    }

    private func chip(_ type: ActivityType?, label: String) -> some View {
        Button {
            filter = type
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(filter == type ? Color.rLime : Color.rSurface.opacity(0.9)))
                .overlay(Capsule().stroke(Color.rBorder, lineWidth: filter == type ? 0 : 1))
                .foregroundStyle(filter == type ? Color.rBackground : .white)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass, eyeball simulator**

Run: `xcodegen generate && xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -5`
Expected: `TEST SUCCEEDED`. In the simulator: Routes tab shows the dark map with filter chips; after Task 13's simulated recording, its lime line is visible and tapping near it opens the workout detail.

- [ ] **Step 5: Commit**

```bash
git add Runner/Features/Routes RunnerTests/RouteHitTestTests.swift
git commit -m "feat: routes — all parcours overlaid with filters and tap-to-open

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 16: Localization (EN + FR)

**Files:**
- Create: `Runner/Resources/Localizable.xcstrings`
- Modify: `project.yml` (declare `CFBundleLocalizations`)

**Interfaces:**
- Consumes: every `String(localized:)` / `Text("…")` literal from Tasks 11–15 (keys are the English strings).
- Produces: French UI when the device language is French. No code changes — the catalog keys must match the English literals **exactly** (copy them from the code, not from memory; `grep -rho 'String(localized: "[^"]*"' Runner/ | sort -u` lists them).

- [ ] **Step 1: Modify project.yml**

In the `info.properties` block of the Runner target, add:

```yaml
        CFBundleLocalizations: [en, fr]
        CFBundleDevelopmentRegion: en
```

- [ ] **Step 2: Write the string catalog**

`Runner/Resources/Localizable.xcstrings` — JSON, `sourceLanguage: en`, one entry per user-facing string with its French translation. Full table (key → fr):

| English (key) | French |
|---|---|
| Run | Course |
| Walk | Marche |
| Bike | Vélo |
| Today | Aujourd'hui |
| History | Historique |
| Routes | Parcours |
| Settings | Réglages |
| Done | OK |
| Record a workout | Enregistrer un entraînement |
| Resume your workout? | Reprendre votre entraînement ? |
| Resume | Reprendre |
| Discard | Abandonner |
| Runner was interrupted mid-workout. Your progress was saved. | Runner a été interrompu en plein entraînement. Votre progression a été sauvegardée. |
| Daily goal | Objectif quotidien |
| Goal | Objectif |
| Permissions | Autorisations |
| Apple Health | Apple Santé |
| Write access denied — points may be incomplete | Écriture refusée — les points peuvent être incomplets |
| Connected | Connecté |
| Location | Localisation |
| Denied — recording won't work | Refusée — l'enregistrement ne fonctionnera pas |
| Ready | Prêt |
| %lld workout(s) waiting to sync to Health | %lld entraînement(s) en attente de synchronisation vers Santé |
| Open iOS Settings | Ouvrir les réglages iOS |
| How points work | Comment fonctionnent les points |
| 1 pt per 100 steps (max 200/day) | 1 pt par 100 pas (max 200/jour) |
| Run: 15 pts per km | Course : 15 pts par km |
| Walk: 10 pts per km | Marche : 10 pts par km |
| Bike: 6 pts per km | Vélo : 6 pts par km |
| Streak: +5% per gold day, max ×1.5 | Série : +5 % par jour en or, max ×1,5 |
| Version | Version |
| GOLD DAY | JOUR EN OR |
| Goal: %lld pts | Objectif : %lld pts |
| %@ steps | %@ pas |
| Latest parcours | Dernier parcours |
| Streak bonus | Bonus de série |
| GO | GO |
| Cancel | Annuler |
| Auto-paused | Pause auto |
| Time | Durée |
| Distance | Distance |
| Pace | Allure |
| Slide to finish | Glisser pour terminer |
| Save workout | Sauvegarder l'entraînement |
| Km %lld | Km %lld |
| Points | Points |
| Saved locally | Sauvegardé localement |
| Apple Health refused the save (%@). The workout is kept in Runner and will retry automatically. | Apple Santé a refusé la sauvegarde (%@). L'entraînement est conservé dans Runner et réessaiera automatiquement. |
| Runner needs location access to draw your parcours. | Runner a besoin de la localisation pour tracer votre parcours. |
| Last 13 weeks | 13 dernières semaines |
| Range | Période |
| Week | Semaine |
| Month | Mois |
| Records | Records |
| Best day | Meilleure journée |
| Best streak | Meilleure série |
| %lld days | %lld jours |
| Longest run | Plus longue course |
| Longest ride | Plus longue sortie vélo |
| Workouts | Entraînements |
| No workouts yet — hit the ▶ button! | Aucun entraînement — appuyez sur ▶ ! |
| No route for this workout (imported from Health) | Pas de tracé pour cet entraînement (importé de Santé) |
| Splits | Intermédiaires |
| All | Tous |
| No routes yet — record a run, walk or ride and your city starts glowing. | Aucun parcours — enregistrez une course, une marche ou une sortie vélo et votre ville s'illumine. |

File format (repeat this structure for every row of the table):

```json
{
  "sourceLanguage" : "en",
  "version" : "1.0",
  "strings" : {
    "Run" : {
      "localizations" : {
        "fr" : { "stringUnit" : { "state" : "translated", "value" : "Course" } }
      }
    },
    "Walk" : {
      "localizations" : {
        "fr" : { "stringUnit" : { "state" : "translated", "value" : "Marche" } }
      }
    }
  }
}
```

Interpolation notes: `String(localized: "\(count) workout(s)…")` extracts as `%lld workout(s)…`; `"\(x.formatted()) steps"` extracts as `%@ steps`; keep the specifiers identical in the French values. Before writing the file, reconcile the table against the actual literals in the code (they win over this table if they drifted).

- [ ] **Step 3: Verify French rendering**

```bash
xcodegen generate
xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' build 2>&1 | tail -3
# reinstall, then launch in French:
xcrun simctl launch RunnerSim com.farid.runner -AppleLanguages "(fr)" -AppleLocale "fr_CA"
sleep 3 && xcrun simctl io RunnerSim screenshot /tmp/runner-fr.png
```

Expected: screenshot shows « Aujourd'hui », « Historique », « Parcours », « Réglages » in the tab bar; Settings shows the French rules. Numbers/dates render in French formats automatically (locale formatters were used throughout).

- [ ] **Step 4: Commit**

```bash
git add Runner/Resources/Localizable.xcstrings project.yml
git commit -m "feat: French localization via string catalog

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 17: App Icon, Haptics, Final Polish

**Files:**
- Create: `scripts/make_icon.swift`
- Create: `Runner/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` (icon PNG generated by the script)
- Create: `Runner/DesignSystem/Haptics.swift`
- Modify: `Runner/Features/Today/TodayView.swift` (delete the placeholder `enum Haptics` at the bottom)
- Modify: `project.yml` (set `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`)

**Interfaces:**
- Consumes: `Haptics.goalReached()` / `Haptics.kmSplit()` call sites created in Tasks 12–13 (signatures unchanged).
- Produces: home-screen icon + real haptic feedback.

- [ ] **Step 1: Icon generator script**

`scripts/make_icon.swift` (run with `swift scripts/make_icon.swift`):

```swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Background #0A0B10
ctx.setFillColor(CGColor(srgbRed: 10/255, green: 11/255, blue: 16/255, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Faint street grid
ctx.setStrokeColor(CGColor(srgbRed: 27/255, green: 32/255, blue: 48/255, alpha: 1))
ctx.setLineWidth(14)
for y in stride(from: 200, through: 824, by: 208) {
    ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: 1024, y: y))
}
for x in stride(from: 200, through: 824, by: 208) {
    ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: 1024))
}
ctx.strokePath()

// Glowing lime route
func route(_ c: CGContext) {
    c.move(to: CGPoint(x: 190, y: 240))
    c.addCurve(to: CGPoint(x: 512, y: 512),
               control1: CGPoint(x: 420, y: 210), control2: CGPoint(x: 350, y: 500))
    c.addCurve(to: CGPoint(x: 840, y: 790),
               control1: CGPoint(x: 700, y: 525), control2: CGPoint(x: 680, y: 810))
}
let lime = CGColor(srgbRed: 200/255, green: 1.0, blue: 0, alpha: 1)
ctx.setShadow(offset: .zero, blur: 90,
              color: CGColor(srgbRed: 200/255, green: 1.0, blue: 0, alpha: 0.85))
ctx.setStrokeColor(lime)
ctx.setLineWidth(58)
ctx.setLineCap(.round)
route(ctx)
ctx.strokePath()

// Start ring + end dot
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.setFillColor(CGColor(srgbRed: 10/255, green: 11/255, blue: 16/255, alpha: 1))
ctx.fillEllipse(in: CGRect(x: 190 - 46, y: 240 - 46, width: 92, height: 92))
ctx.setStrokeColor(lime)
ctx.setLineWidth(30)
ctx.strokeEllipse(in: CGRect(x: 190 - 46, y: 240 - 46, width: 92, height: 92))
ctx.setFillColor(lime)
ctx.fillEllipse(in: CGRect(x: 840 - 52, y: 790 - 52, width: 104, height: 104))

let image = ctx.makeImage()!
let out = URL(fileURLWithPath: "Runner/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png")
try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
```

`Runner/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`:

```json
{
  "images" : [
    {
      "filename" : "icon_1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

In `project.yml`, under the Runner target `settings.base`, add:

```yaml
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
```

Run: `swift scripts/make_icon.swift`
Expected: `wrote Runner/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png` — open the PNG to eyeball it (dark tile, glowing lime route, start ring, end dot).

- [ ] **Step 2: Real haptics**

`Runner/DesignSystem/Haptics.swift`:

```swift
import UIKit

enum Haptics {
    static func goalReached() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func kmSplit() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
```

Then in `Runner/Features/Today/TodayView.swift`, delete the placeholder at the bottom of the file:

```swift
/// Task 17 upgrades this to real haptic feedback; keep the seam now so call
/// sites don't change.
enum Haptics {
    static func goalReached() {}
    static func kmSplit() {}
}
```

(Call sites in TodayView and RecordView keep working unchanged.)

- [ ] **Step 3: Build, test, verify icon**

```bash
xcodegen generate
xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -5
```

Expected: `TEST SUCCEEDED`. Reinstall in simulator, go to the home screen (`xcrun simctl io RunnerSim screenshot /tmp/runner-icon.png` after pressing home via Device menu) — the Runner icon shows the lime route on dark.

- [ ] **Step 4: Commit**

```bash
git add scripts/make_icon.swift Runner/Resources/Assets.xcassets/AppIcon.appiconset Runner/DesignSystem/Haptics.swift Runner/Features/Today/TodayView.swift project.yml
git commit -m "feat: app icon, real haptics for goal + km splits

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 18: Deploy Script, README, Final Validation

**Files:**
- Create: `scripts/deploy.sh`
- Create: `README.md`

**Interfaces:**
- Consumes: everything.
- Produces: the shipped app on Farid's iPhone + the success-criteria checklist result.

- [ ] **Step 1: Write deploy.sh**

`scripts/deploy.sh` (then `chmod +x scripts/deploy.sh`):

```bash
#!/usr/bin/env bash
# Deploy Runner to a cable-connected iPhone (free Apple ID: re-run weekly).
# First time only, in Xcode: Settings ▸ Accounts ▸ add your Apple ID.
# On the iPhone: enable Developer Mode (Settings ▸ Privacy & Security), trust this Mac,
# and after the first install trust the developer cert (Settings ▸ General ▸ VPN & Device Management).
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null && xcodegen generate

JSON=$(mktemp)
xcrun devicectl list devices --json-output "$JSON" >/dev/null
UDID=$(python3 - "$JSON" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for device in data.get("result", {}).get("devices", []):
    hw = device.get("hardwareProperties", {})
    conn = device.get("connectionProperties", {})
    if hw.get("platform") == "iOS" and conn.get("pairingState", "paired") == "paired":
        print(hw.get("udid", ""))
        break
PY
)
if [ -z "${UDID}" ]; then
  echo "❌ No iPhone found. Connect it with a cable, unlock it, and tap 'Trust'." >&2
  exit 1
fi
echo "📱 Deploying to device ${UDID}"

BUILD_ARGS=(-project Runner.xcodeproj -scheme Runner -destination "id=${UDID}" -allowProvisioningUpdates)
[ -n "${TEAM_ID:-}" ] && BUILD_ARGS+=("DEVELOPMENT_TEAM=${TEAM_ID}")
xcodebuild "${BUILD_ARGS[@]}" build

PRODUCTS_DIR=$(xcodebuild "${BUILD_ARGS[@]}" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
xcrun devicectl device install app --device "${UDID}" "${PRODUCTS_DIR}/Runner.app"
xcrun devicectl device process launch --device "${UDID}" com.farid.runner || true
echo "✅ Runner deployed. Free-account signature lasts ~7 days — rerun this script weekly."
```

If `xcodebuild` fails with a signing error on first run: open `Runner.xcodeproj` in Xcode once, select the Runner target ▸ Signing & Capabilities, pick the Personal Team, then re-run the script (pass `TEAM_ID=XXXXXXXXXX` afterwards to stay scriptable — the team ID is shown in Xcode ▸ Settings ▸ Accounts).

- [ ] **Step 2: Write README.md**

```markdown
# Runner ⚡

Personal iPhone fitness app: daily points from steps + GPS-recorded
runs/walks/rides, glowing route maps, streaks. Dark "Electric Night" UI,
English + French. Apple Health is the system of record.

## Points
1 pt / 100 steps (cap 200/day) · Run 15/km · Walk 10/km · Bike 6/km ·
streak +5%/gold day (max ×1.5) · default goal 100 pts (Settings).

## Develop
```bash
brew install xcodegen          # once
xcodegen generate              # after any file add/remove
xcodebuild -project Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,name=RunnerSim' test
```

## Deploy to iPhone (free Apple ID)
```bash
scripts/deploy.sh              # cable + unlocked phone; rerun weekly
```
Your data always survives redeploys: workouts live in Apple Health,
the local cache rebuilds itself.

## Layout
`Runner/Core` — pure logic (points, ledger, GPS filter) + gateways
(HealthKit, CoreLocation, SwiftData). `Runner/Features` — SwiftUI
screens (Today, Record, History, Routes, Settings).
Spec: `docs/superpowers/specs/2026-07-05-runner-fitness-app-design.md`.
```

- [ ] **Step 3: Full test suite + simulator regression**

```bash
xcodebuild -project Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=RunnerSim' test 2>&1 | tail -10
```

Expected: `TEST SUCCEEDED`, all suites green (Points, Ledger, DataStore, Filter, AutoPause, Checkpoint, Recorder, Mappers, Sync, AppModel, Format, HistoryMath, RouteHitTest, Theme, Smoke).

- [ ] **Step 4: Device deployment + success-criteria checklist (with Farid)**

Run `scripts/deploy.sh` with the iPhone connected. Then walk the spec §14 checklist on the device:

1. ☐ Open Runner → today's points + breakdown visible, no interaction (steps from Health backfill).
2. ☐ History shows heatmap/charts/streaks computed from ~90 days of past steps on first launch.
3. ☐ Record a short real walk outside → live points tick, route draws, summary saves.
4. ☐ Open Apple Health ▸ Browse ▸ Activity ▸ Workouts → the walk is there (source: Runner) with its route on the map.
5. ☐ Start a recording, force-kill Runner, relaunch → "Resume your workout?" appears; resume works, ≤30 s lost.
6. ☐ iPhone language set to French → full French UI.

Each unchecked box is a bug: fix before calling v1 done.

- [ ] **Step 5: Final commit**

```bash
git add scripts/deploy.sh README.md
git commit -m "feat: deploy script and README — v1 complete

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Plan Self-Review Notes

- **Spec coverage:** §3 screens → Tasks 11–15; §4 points/backfill → 3, 4, 10; §5 data → 5, 9, 10; §6 GPS → 6, 7, 8; §7 visuals → 2, 12–15, 17; §8 errors → 8 (gaps/checkpoints), 10 (pending retry), 11/13 (permission UX + resume alert), 12 (sync error banner); §9 i18n → 16; §10 testing → every task; §12 deployment → 18. Out-of-scope items (§13) deliberately absent.
- **Known simplifications (intentional, spec-consistent):** external workouts get `movingSeconds: 0` (no pace shown, "—"); routes stored as JSON (~300 KB for a 2 h ride — fine for v1); HealthKit read-denial is indistinguishable from no-data by iOS design — Settings explains write status only.




