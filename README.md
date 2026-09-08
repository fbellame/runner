# Runner

Personal iPhone fitness app: daily points from steps plus GPS-recorded
runs/walks/rides, glowing route maps, streaks. Dark "Electric Night" UI,
English and French. Apple Health is the system of record.

**[docs/SPEC.md](docs/SPEC.md) is the current specification** — one document,
kept up to date. Read section 15 (Invariants) before touching `Core/Recording`.
The per-epic designs under `docs/superpowers/` are a historical log.

## Points

1 pt / 100 steps (cap 200/day). Run 15/km. Walk 10/km. Bike 6/km.
Streak +5%/gold day (max x1.5). Default goal 100 pts in Settings.

## Develop

```bash
brew install xcodegen
xcodegen generate
xcodebuild test -project Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,name=RunnerSim' \
  DEVELOPMENT_TEAM=QPX8CS262Z CODE_SIGNING_ALLOWED=NO
```

## CI

Every pull request into `main` runs the whole suite on a simulator
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)): XcodeGen regenerates
the project, `xcodebuild test` runs it unsigned on the newest iPhone simulator
of the runner, and per-target line coverage is printed in the run summary. A
failing run uploads `TestResults.xcresult` as an artifact.

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

Spec: [`docs/SPEC.md`](docs/SPEC.md). The per-epic designs under
`docs/superpowers/` are a historical log, not maintained.
