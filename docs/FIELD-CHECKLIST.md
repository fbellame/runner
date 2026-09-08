# Field checklist

One outdoor session that closes [`SPEC.md` §16](SPEC.md). Everything in §16 is
unverified for the same reason: it needs GPS, CoreMotion, HealthKit, ActivityKit
or Siri, and the simulator has none of them. The suite cannot shrink that list by
a single line, no matter how large it gets.

Do the whole thing in one walk or run of **20 minutes or more** — the auto-pause
profile needs a real stop, and the trace needs enough samples to be worth
replaying.

## Before leaving

- [ ] `scripts/deploy.sh` — phone unlocked, cable attached.
- [ ] Developer cert still trusted (Settings → General → VPN & Device
      Management). A free Apple ID signature lasts ~7 days.
- [ ] Open the app once and let it reach Today, so HealthKit auth and the
      foreground sync are out of the way.
- [ ] Note the build number shown against `project.yml`'s `CFBundleVersion` —
      an install that silently didn't replace the old app invalidates the run.

## During — §16 item 1: Siri

**Never confirmed on device.** Built 2026-07-29; twelve features have shipped on
top of it since. French phrases live in `AppShortcuts.xcstrings`;
`INAlternativeAppNames` is Course / Run.

- [ ] "Dis Siri, démarre une course avec Runner" — screen locked. Run arms.
- [ ] The phone is **not** asked to unlock (§15.6). If it is, stop and note it.
- [ ] "Mets Runner en pause" → paused. "Reprends ma course" → resumed.
- [ ] "Comment va ma course" → speaks a distance and a duration that match the
      Live Activity.
- [ ] "Termine ma course avec Runner" → saved, and the summary is waiting on
      next open.
- [ ] Whatever phrasing *fails*, write it down verbatim. A phrase Siri won't
      match is the finding, not a mistake.

## During — §16 item 2: motion gate and traces

**Shipped in build 21, merged before field validation.** The gate may only
refuse to start or resume, never cause or delay a pause (§15.3).

- [ ] Start a run and stand still for ~30 s before moving. It should **not**
      start the clock, and `startedAt` should rebase to when you actually move.
- [ ] Run normally for 5+ minutes.
- [ ] **Stop dead for 60 s at a light or a corner.** Auto-pause should fire in
      about 6 s (§7.3 is deliberately aggressive — do not "fix" it if it feels
      eager, that is the chosen trade).
- [ ] Walk off again. Resume should be near-instant above 1.5 m/s.
- [ ] Manually pause for a minute, then resume — the trace records both as
      `mark` rows; without them a manual pause looks exactly like a dead signal.
- [ ] Go under a bridge or into a tunnel if there is one. The timer keeps
      running through GPS gaps (§15.10); the map must not draw a straight line
      across the gap.
- [ ] Finish. Confirm it announces *and* that the distance is not 0.00 km
      (§15.11 — a zero-distance workout is never stored).

## During — §16 item 3: the 2026-09-05 audit fixes

Twenty defects, **proven only against the test suite.** These are the ones with
a visible surface:

- [ ] **Routes tab frames your routes** — the map opens on the run you just did,
      not on downtown Montreal. (This is the one that was invisible because the
      fallback happens to be home.)
- [ ] Tap between the All / Run / Walk / Bike chips: the camera re-frames each
      time and the taps stay instant.
- [ ] **Activity hub → Progression → "12 wk"** draws twelve bars, not one.
      Check "1 yr" and "All" too.
- [ ] **Records:** no "Fastest 1 km" showing a blank "—". A split under 120 s/km
      did not happen (§15.12).
- [ ] **Splits** are numbered contiguously — no km 4 labelled "Km 3".
- [ ] **Weekly recap** says "Best effort", and it is genuinely the best of any
      type, not just the longest.
- [ ] **Monthly Wrapped banner:** tap the ✕. It goes away *immediately* and
      stays away after a relaunch.
- [ ] **Settings → daily goal:** type something out of range, leave, come back.
      The clamped value persisted.
- [ ] **Profile → weight:** edit it, then force-quit without navigating back.
      The edit survived (weight gates every calorie number).
- [ ] A bike ride shows a CO₂ figure whether Runner recorded it or Bixi did.

## Back at the desk — the part that makes it permanent

This is the step that has never been done, and the reason §7.6's promise is
still unfulfilled: `TraceReplay` works, but **no real trace has ever been
committed**, so every replay test feeds it a synthetic trace — the hand-rolled
noise model the spec explicitly says not to invent.

1. Pull the traces. `UIFileSharingEnabled` exposes them, so Files → On My iPhone
   → Runner → Diagnostics, or over the cable:
   ```bash
   xcrun devicectl device info files --device <UDID> \
     --domain-type appDataContainer --domain-identifier com.farid.runner \
     --username mobile --source Documents/Diagnostics --destination ./traces
   ```
2. Pick the session with the most interesting failure — an auto-pause that fired
   late, a resume that didn't, a gap the timer got wrong. **A run that behaved
   perfectly is worth committing too**, as the baseline.
3. Commit it under `RunnerTests/Fixtures/` with a name that says what it shows
   (`2026-09-08-late-autopause.csv`), and add a test that replays it through
   `WorkoutRecorder` and asserts the verdict you actually observed outside.
   `SessionTraceTests.aWrittenTraceReplaysThroughTheRecorder` is the shape.
4. Update §16: strike what this session proved, and leave what it didn't.

## If something misbehaved

Don't tune from memory — that has been done twice and both rounds were guesswork
about a signal nobody had looked at. The trace **is** the signal. Read the CSV
first (`usedSpeed` versus `sensorSpeed`, the `state` column, the `event`
transitions), then change the code, then replay the same file to prove it.

Before touching anything in `Core/Recording`, read §15. Every invariant there was
paid for with a bug, and §15.5 in particular says the aggressive stop detection
is a deliberate choice, not a defect to be softened.
