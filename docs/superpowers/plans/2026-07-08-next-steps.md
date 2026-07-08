# Runner — Next Steps (session handoff)

**Written:** 2026-07-08 · **Branch:** `runner-v1` · **App version:** 1.3 (build 5)

Handoff so a fresh session can resume cold. Everything below is committed and
pushed; the open **PR #2** (`runner-v1` → main) carries it all.

## Where things stand

- **v1.2 History & Trends** (4 phases) and **v1.3 Richer HealthKit** are shipped and
  deployed to the physical iPhone. 142 tests / 22 suites green.
- Established working method (keep using it): each feature = brainstorm → spec in
  `docs/superpowers/specs/` → implement (bulk via Codex `codex:codex-rescue` with a
  full cold-start brief) → review diff → `xcodegen generate` → `xcodebuild … build
  test` on iPhone 17 sim → commit → deploy.
- **Key domain fact:** the user's HealthKit data is ~718 **Bixi** (bike-share) rides
  with **no distance**, plus walk/run only as `distanceWalkingRunning` samples (not
  workouts). v1.3 estimates Bixi distance (duration × ~15 km/h, shown with `~`).
- Diagnostics live at **Settings → HealthKit diagnostics** (`HealthStore.diagnosticsReport()`).

## Immediate housekeeping (do first, ~5 min)

1. **Confirm v1.3 in the wild is still correct** after real use (Bixi show `~km` +
   points; history reaches back). Already verified by the user, so just a sanity check.
2. **Decide PR #2 fate:** merge `runner-v1` → `main`, or keep accumulating. If merging,
   consider starting the next feature on a fresh branch off updated `main`.

## Candidate next features (prioritized — each needs its own spec)

### 1. Richer HealthKit metrics ("En Forme" parity) — RECOMMENDED next
The user explicitly wants Runner to leverage more, like their "En Forme" app.
- **Elevation / dénivelé:** cycling/hiking climb. Read `HKQuantityTypeIdentifier
  .flightsClimbed` and/or workout route altitude; surface per-workout + trends.
- **Active energy:** read `activeEnergyBurned` from HealthKit as an alternative/
  cross-check to the current MET-based `CalorieEngine` estimate.
- **Heart rate (optional):** avg/max per workout from `HKQuantityType(.heartRate)`.
- Add these to `readTypes`, extend `ExternalWorkout`/`WorkoutRec` (inline-default
  fields → migration-safe, mirror `distanceEstimated`/`calories`), thread into detail
  views and possibly Insights. Use the diagnostics screen to confirm what the device
  actually has before building.
- **Decision needed:** which metrics matter most to the user, and where they surface
  (Workout Detail only, or Today/Insights too).

### 2. Make ambient walk/run more visible
v1.3 only folds walk/run distance into daily totals. Options to consider (needs a
decision — each has tradeoffs around double-counting and "fake sessions"):
- Show a daily "walking" summary row on Today/Day Detail.
- Optionally award points for walk/run distance (careful: steps already do — avoid
  double count).

### 3. Tune the Bixi distance estimate
- ~15 km/h is a guess. Consider making it configurable, or refining per ride length.
- Consider excluding very short (<1 min) rides from records so an estimate can't win
  "Longest ride" unfairly.

### 4. Backfill performance
- First full backfill builds one ledger per day back to the earliest sample (2018 →
  ~3000 days). It's one-time but heavy. If it ever feels slow, consider chunking or a
  progress indicator; the "Re-import full history" button re-triggers it.

## How to resume (commands)

```bash
cd /Users/farid/projects/running
git checkout runner-v1 && git pull
xcodegen generate
xcodebuild -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' build test
./scripts/deploy.sh          # cable-connected iPhone; unlock it so launch succeeds
```

**Deploy gotchas:** free Apple ID signature lasts ~7 days (rerun weekly). Set version
in `project.yml` `info.properties` (`CFBundleShortVersionString` / `CFBundleVersion`)
— XcodeGen ignores the equivalent build settings for the plist. Bump `CFBundleVersion`
each deploy so iOS treats it as a real update. Version shows in Settings + Profile footer.

## Pointers
- Memory: `v1.2-history-trends-epic.md` (has the v1.3 follow-on + domain facts).
- Specs: `docs/superpowers/specs/2026-07-08-*` (5 specs: activity-detail, insights,
  split-analytics, full-history-import, weekly-recap, richer-healthkit).
- Recommended first action next session: **brainstorm feature #1 (richer metrics)** to
  pick which metrics and where they surface, then spec → implement.
