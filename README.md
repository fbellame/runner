# Runner

Personal iPhone fitness app: daily points from steps plus GPS-recorded
runs/walks/rides, glowing route maps, streaks. Dark "Electric Night" UI,
English and French. Apple Health is the system of record.

## Points

1 pt / 100 steps (cap 200/day). Run 15/km. Walk 10/km. Bike 6/km.
Streak +5%/gold day (max x1.5). Default goal 100 pts in Settings.

## Develop

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,name=RunnerSim' test
```

## Deploy to iPhone

```bash
scripts/deploy.sh
```

Use a cable and unlocked phone. With a free Apple ID, rerun weekly.

Your data survives redeploys: workouts live in Apple Health, and the local
cache rebuilds itself.

## Layout

`Runner/Core` contains pure logic (points, ledger, GPS filter) and gateways
(HealthKit, CoreLocation, SwiftData). `Runner/Features` contains SwiftUI
screens (Today, Record, History, Routes, Settings).

Spec: `docs/superpowers/specs/2026-07-05-runner-fitness-app-design.md`.
