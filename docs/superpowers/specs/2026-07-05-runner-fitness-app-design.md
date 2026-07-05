# Runner — iPhone Fitness App Design

**Date:** 2026-07-05
**Status:** Approved pending user review
**Owner:** Farid (faridautomatic@gmail.com)

## 1. What & Why

Runner is a personal iPhone app that makes daily movement feel like winning. It replaces the flat dashboards of Google Fit / Apple Health with one motivating number — **daily points** — earned from all-day steps and GPS-recorded workouts (run / walk / bike), each drawn as a glowing route map (parcours). Dark, neon, high-energy "Electric Night" visual identity.

**User context (decisions from brainstorming):**

- Farid tracks with **iPhone only, in pocket** — no Apple Watch, no Strava. HealthKit has all-day steps but **no GPS routes and no bike data**, so the app records workouts itself with GPS.
- Points system: **smart composite** (steps + weighted workout distance + streak multiplier).
- Visual direction: **Electric Night** (chosen from 3 mockups).
- Languages: **English + French**, following the iPhone's system language. Metric units.
- Deployment: **free Apple ID** — cable install from Xcode, re-sign weekly.
- Name: **Runner** (user's choice, "keep it simple"). Bundle ID `com.farid.runner`.

## 2. Platform & Stack

- **Swift 6 / SwiftUI**, iOS 18.0 minimum (Farid's device assumed on iOS 18+; verify at first deploy — lower to 17 only if needed).
- **Xcode 26.6** (installed on this Mac), personal team signing.
- **HealthKit** — read steps (+ any workouts other apps contribute); write recorded workouts & routes.
- **CoreLocation** — GPS workout recording with background updates (When-In-Use permission + `location` background mode; session always starts in foreground).
- **MapKit for SwiftUI** — dark-scheme maps, `MapPolyline` routes.
- **Swift Charts** — history graphs.
- **SwiftData** — local cache/ledger.
- No third-party dependencies.

## 3. App Structure

Four destinations; Record is the raised center button:

```
┌──────────────────────────────────────────┐
│  ⚡ Today   📊 History   (▶)   🗺️ Routes  │
└──────────────────────────────────────────┘
```

### ⚡ Today (home)
- Date header; big glowing points total; progress bar → daily goal; gold-day state when goal met.
- Breakdown list: steps line, one line per workout, streak multiplier line. Every point accounted for, always.
- Mini-map card of today's most recent workout route (hidden if none).
- Streak flame with day count.

### ▶ Record
- Full-screen dark map with user location.
- Activity picker: Run 🏃 / Walk 🚶 / Bike 🚴 → big GO.
- Live HUD: elapsed time, distance (km), pace (min/km), **points ticking up live** at the activity's per-km rate.
- Auto-pause indication; manual pause/resume; slide-to-finish (prevents pocket-stops).
- Finish → summary card: route polyline in glowing lime, distance, duration, pace, splits per km, points earned. Save or discard.

### 📊 History
- GitHub-style calendar heatmap — lime intensity = points per day.
- Weekly / monthly bar charts (Swift Charts) with goal rule-line.
- Workout list (reverse-chron); tap → detail: full-screen route, stats, splits.
- Records card: best day, longest run/ride, current & best streak.

### 🗺️ Routes
- All recorded parcours overlaid on one dark map — the city painted lime over time.
- Tap a route → workout detail. Filter chips: All / Run / Walk / Bike.

### Settings (sheet from Today)
- Daily goal (default 100 pts; range 50–500, step 10).
- Permissions status (Health / Location) with fix-it buttons.
- About + points rules explainer.

## 4. Points Engine (exact rules)

Displayed in-app; transparency is a feature.

| Source | Rule |
|---|---|
| Steps (all-day, HealthKit) | `floor(steps / 100)` pts, capped at **200 pts/day** |
| Recorded Run | `round(km × 15)` pts |
| Recorded Walk | `round(km × 10)` pts |
| Recorded Bike | `round(km × 6)` pts |
| Streak multiplier | `min(1 + 0.05 × n, 1.5)`, n = consecutive gold days **before** today |

- **Day total** = `round((stepPts + Σ workoutPts) × multiplier)`.
- **Gold day** = total ≥ goal. Streak = consecutive gold days; a missed day resets the multiplier to ×1.0.
- Multiplier uses the streak *entering* the day (yesterday backward) — no circular dependency on today's own result.
- A day = local midnight → midnight. On day rollover, yesterday is finalized with the goal value that was set that day (`goalAtThatTime`).
- Step/run double-counting is **intentional**: a recorded run also raises the day's step count; workouts are meant to feel like a bonus on top of ambient movement.
- Workouts imported from HealthKit (future watch/Strava) score by the same distance rules; their steps are already in the daily count.
- Live recording display: `floor(currentKm × rate)` ticking up; final value uses the rounded rule above.

### Backfill
On first launch (after Health permission): read **90 days** of daily step counts + any existing HealthKit workouts → build the full ledger, streaks included. The app starts with history, not an empty state.

## 5. Data Architecture

**Apple Health is the system of record. SwiftData is a rebuildable cache.**

- **Write path:** finished recording → `HKWorkout` (running/walking/cycling) + `HKWorkoutRoute` (GPS samples) + distance saved to HealthKit → SwiftData cache row written on success (workout kept in a pending queue and retried if the Health write fails).
- **Read path:** daily steps via `HKStatisticsCollectionQuery`; `HKObserverQuery` + background delivery refreshes today's steps; foreground refresh on every app open.
- Weekly re-deploys (free signing) and reinstalls never lose data: HealthKit persists; the cache rebuilds from HealthKit + checkpoint files.

**SwiftData models:**

```
DayLedger    date (unique, startOfDay) · steps · stepPoints · workoutPoints
             multiplier · totalPoints · goalAtThatTime · isGold
WorkoutRec   id (= HealthKit UUID) · type · start · end · duration
             distanceMeters · points · encodedPolyline · splits[] · hkSynced
```

`DayLedger` recomputes from sources whenever inputs change (new steps, new/deleted workout, goal edit affects only today forward).

## 6. GPS Recording (Core/Recording)

- `CLLocationManager`: `kCLLocationAccuracyBest`, `activityType = .fitness`, `allowsBackgroundLocationUpdates = true`, own auto-pause (`pausesLocationUpdatesAutomatically = false`), `showsBackgroundLocationIndicator = true`.
- **Filtering:** drop samples with `horizontalAccuracy > 30 m` or older than 10 s; minimum displacement 3 m between kept points.
- **Distance** = sum of consecutive kept-point distances. **Splits** recorded at each km.
- **Auto-pause:** run/walk — speed < 0.5 m/s for 10 s; bike — < 1.0 m/s for 15 s. Resume at speed above threshold for 3 s. Paused time excluded from duration/pace.
- **Crash safety:** checkpoint (JSON lines: meta + points so far) to Application Support every 30 s and on pause/resume; on next launch, an unfinished checkpoint triggers *"Resume your workout?"* (resume or save-as-is). Deleted on clean finish.
- **GPS gaps** (tunnel etc.): timer continues, polyline renders a dotted gap segment, distance resumes on reacquisition — the workout is never lost or aborted.

## 7. Visual Design — "Electric Night"

| Token | Value |
|---|---|
| Background | `#0A0B10` |
| Surface / card | `#141824`, border `#232B3D` |
| Primary (points, routes) | Lime `#C8FF00` with glow shadows |
| Run accent | Teal `#3DF5C6` |
| Bike accent | Purple `#B48CFF` |
| Streak | Orange `#FF7A3D` |
| Secondary text | `#8A8F9E` |

- Numbers in SF Pro Rounded, heavy weights, large; uppercase micro-labels with wide tracking.
- Maps: MapKit standard style forced to dark; route stroke lime 4 pt over a soft glow underlay; start ring / end dot markers.
- Dark mode only (it's the identity).
- Charts: lime bars, goal rule-line, gold-day dots.
- Haptics: km-split tick, goal-reached celebration (glow burst animation on Today).
- App icon: lime route squiggle forming a "⚡" on near-black.

## 8. Error Handling

| Failure | Behavior |
|---|---|
| Health permission denied | Today shows explainer card + button → iOS Settings deep link. Never silent zeros. |
| Location denied / reduced accuracy | Record screen explains + Settings link; precise-location request when reduced. |
| GPS signal loss | Keep timer; dotted route gap; auto-recover. |
| App killed / battery dies mid-workout | 30 s checkpoints → resume prompt on relaunch. Max 30 s of route lost. |
| HealthKit write fails | Workout kept locally in pending queue, retried on next launch/foreground; badge in Settings. |
| Day rollover while app open | Ledger finalizes yesterday, Today resets, streak recomputes. |

## 9. Internationalization

- String Catalog (`Localizable.xcstrings`): English (base) + French. UI follows system language.
- French uses proper vocabulary: *parcours, course, marche, vélo, série (streak), jour en or (gold day)*.
- Metric only (km, min/km). Dates/numbers via system locale formatters.

## 10. Testing

- **PointsEngine** — pure Swift, no iOS imports; unit tests: caps, rounding, multiplier boundaries (0/1/10/11-day streaks), goal edits, midnight rollover, DST days, backfill reconstruction, empty days.
- **WorkoutRecorder** — feed synthetic `CLLocation` arrays: distance accuracy, accuracy-filter behavior, auto-pause enter/exit, split boundaries, checkpoint/restore round-trip.
- **HealthStore** — behind a protocol; fake in tests; real implementation exercised manually.
- **Simulator**: Xcode simulated locations ("City Run", GPX files) for end-to-end record flow.
- **Device validation**: real run + walk + bike with phone in pocket before calling v1 done.

## 11. Project Layout

```
Runner.xcodeproj
Runner/
  App/                 RunnerApp, RootTabView, theme
  Features/Today/      Features/Record/   Features/History/   Features/Routes/
  Core/PointsEngine/   (pure logic)
  Core/Health/         (HealthStore protocol + HealthKit impl)
  Core/Recording/      (WorkoutRecorder, checkpoints)
  Core/Store/          (SwiftData models, ledger recompute)
  DesignSystem/        (colors, type, components, glow, haptics)
  Resources/           (Localizable.xcstrings, assets)
RunnerTests/
```

## 12. Deployment

- Free Apple ID personal team; build to device by cable. Signature lifetime 7 days → weekly one-command redeploy (script: `scripts/deploy.sh` wrapping `xcodebuild … install` to the connected device).
- HealthKit + Background Modes (location) entitlements both work with free provisioning.
- Data survives every redeploy (HealthKit + on-device store).
- Upgrade path (later, optional): $99 Apple Developer → TestFlight 90-day builds → App Store.

## 13. Out of Scope (v1)

- Apple Watch app, widgets, Live Activities (Dynamic Island during recording — v1.1 candidate).
- Social features, sharing images, leaderboards.
- Notifications ("streak at risk" reminder — v1.1 candidate).
- Auto-detection of workouts without pressing Record.
- Calories/heart-rate (no sensor available).
- App Store release.

## 14. Success Criteria

1. Open the app any day → today's points with full breakdown, no interaction needed.
2. Record a run/walk/ride → live points + route; finished parcours renders on a dark map in lime.
3. History shows heatmap + charts from 90 days of backfilled steps on day one.
4. Workout data verifiably lands in Apple Health (visible in the Health app).
5. Kill the app mid-run → relaunch offers resume; at most ~30 s of route lost.
6. Full UI in French when the phone is in French.
