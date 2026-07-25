import Foundation
import ActivityKit

/// The real `LiveActivityPresenting` implementation: owns the single
/// `Activity<RunAttributes>` for the run currently on screen and talks to
/// ActivityKit. Every ActivityKit call that requires `await` is hopped onto
/// its own `Task { }` so `begin`/`update`/`end` stay synchronous — callers
/// (`WorkoutRecorder`'s hot path) must never suspend.
@MainActor
final class LiveActivityController: LiveActivityPresenting {
    // ActivityKit predates Swift 6 concurrency annotations: `Activity<Attributes>`
    // is a plain class with no `Sendable` conformance in this SDK, so it can't be
    // captured directly by the `@Sendable` `Task { }` closures below. Rather than
    // asserting Sendable on `Activity` itself — which would apply to every
    // `Activity<Attributes>` specialization module-wide, including any future
    // ActivityKit use elsewhere that would then get zero compiler help — this
    // box asserts only the one thing that is actually true and only for the
    // `Activity<RunAttributes>` this controller hands into its own `Task`s:
    // it's safe to move across that hop because every ActivityKit call this
    // controller makes on it is itself `@MainActor`-safe to originate from and
    // nothing here mutates shared state off the main actor. `private` and
    // file-scoped so the assertion can't leak to any other file.
    private struct SendableActivityBox: @unchecked Sendable {
        let activity: Activity<RunAttributes>
    }

    private var activity: Activity<RunAttributes>?
    private var previous: RunActivitySnapshot?
    private var lastUpdateAt: Date?
    private let clock: () -> Date

    // Fix wave 3: when non-matching strays exist, `begin()` must end them
    // ALL before calling `Activity.request` (see the stray-clearing branch
    // below), which means `begin()` can now return before `activity` is
    // set. That gap opens two races (re-entrancy, and `end()`/`discard()`
    // racing the deferred request) — see `LiveActivityRequestGate`'s doc
    // comment for the full analysis. The state itself is pulled out into
    // that separate, ActivityKit-free type (same precedent as
    // `LiveActivityOrphanSelector`) so it's unit-testable on its own.
    private var requestGate = LiveActivityRequestGate()

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    func begin(_ snapshot: RunActivitySnapshot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              activity == nil,
              !requestGate.isInFlight else { return }

        // ActivityKit activities outlive this process. If the app was
        // killed mid-run (jetsam, force-quit, or a crash while the summary
        // sheet was still open), no `end` ever ran — the OS is still
        // showing that (now-stale) Live Activity on the lock screen even
        // though a fresh process's `activity` here is `nil`. Requesting a
        // new one unconditionally would put TWO Live Activities for the
        // same run on the lock screen (one frozen pre-crash, one live), and
        // finishing/saving would only ever end the new one. Adopt an
        // existing activity instead of blindly requesting a new one —
        // but ONLY when it belongs to the same run that is now starting.
        // A brand-new run starting while an unrelated orphan survives must
        // end that stray and request a fresh activity of its own, not
        // silently inherit the orphan's identity.
        //
        // Adoption (rather than always ending every stray and requesting
        // fresh) is chosen deliberately for the matching case: ending an
        // activity and immediately requesting a new one is visibly a
        // dismiss-then-reappear on the lock screen the user cannot see
        // happen (phone is zipped away) but WILL see when they eventually
        // look — the entry would appear to have reset. Adopting keeps the
        // existing lock-screen entry in place and simply refreshes its
        // content, which is the more honest continuation of "the run that
        // was already showing here."
        //
        // Session identity is `RunActivitySnapshot.startedAt`: `WorkoutRecorder`
        // restores `startedAt` from the checkpoint on a crash-resume
        // (`WorkoutRecorder.start(resumeFrom:)`), so a resumed run presents
        // the same value the orphaned activity was last showing, while a
        // genuinely new run gets a fresh `startedAt` that cannot collide.
        let existing = Activity<RunAttributes>.activities
        let decision = LiveActivityOrphanSelector.decide(
            existingSessionKeys: existing.map { $0.content.state.snapshot.startedAt },
            incoming: snapshot.startedAt
        )

        if let adoptIndex = decision.adoptIndex {
            // Adoption path: unchanged from before fix wave 3. No `request`
            // is involved, so there is no ordering requirement between
            // ending the extras and refreshing the adopted activity's
            // content — both are pushed as independent, fire-and-forget
            // tasks, exactly as today.
            for index in decision.endIndices {
                let box = SendableActivityBox(activity: existing[index])
                Task { await box.activity.end(nil, dismissalPolicy: .immediate) }
            }
            let adopted = existing[adoptIndex]
            activity = adopted
            // The adopted activity's content is whatever it last showed
            // before the crash — push the current snapshot right away so
            // the lock screen stops showing stale pre-crash numbers instead
            // of waiting for the next naturally-throttled `update()` call.
            let box = SendableActivityBox(activity: adopted)
            Task {
                await box.activity.update(ActivityContent(
                    state: RunAttributes.ContentState(snapshot: snapshot),
                    staleDate: nil
                ))
            }
            previous = snapshot
            lastUpdateAt = clock()
            return
        }

        guard !decision.endIndices.isEmpty else {
            // No strays and no match: request synchronously, exactly as
            // before fix wave 3 — but only commit bookkeeping if the
            // request actually succeeded, so a rejected request never
            // leaves `activity`/`previous`/`lastUpdateAt` pointing at an
            // activity that does not exist.
            let content = ActivityContent(
                state: RunAttributes.ContentState(snapshot: snapshot),
                staleDate: nil
            )
            guard let requested = try? Activity.request(
                attributes: RunAttributes(sessionID: UUID()),
                content: content,
                pushType: nil
            ) else { return }
            activity = requested
            previous = snapshot
            lastUpdateAt = clock()
            return
        }

        // Strays exist and none match: ActivityKit enforces a limit on
        // concurrent activities, so requesting while every stray is still
        // live risks a silent rejection. End them all first — sequentially,
        // awaited, inside ONE controller-scoped task — and only then
        // request and commit bookkeeping. `begin()` itself stays
        // synchronous (WorkoutRecorder's hot path must never suspend); see
        // `LiveActivityRequestGate` for how the two races this deferral
        // opens are closed.
        let strays = decision.endIndices.map { SendableActivityBox(activity: existing[$0]) }
        let token = requestGate.start()
        Task { [weak self] in
            for stray in strays {
                await stray.activity.end(nil, dismissalPolicy: .immediate)
            }
            await self?.finishDeferredRequest(snapshot: snapshot, token: token)
        }
    }

    /// Completes the deferred half of `begin()`'s stray-clearing branch:
    /// requests a fresh activity and commits bookkeeping, but only if
    /// `requestGate.shouldProceed(token)` confirms nothing invalidated this
    /// attempt (a newer `begin()` or an `end()`) while the strays were
    /// being ended.
    private func finishDeferredRequest(snapshot: RunActivitySnapshot, token: Int) async {
        guard requestGate.shouldProceed(token) else { return }
        let content = ActivityContent(
            state: RunAttributes.ContentState(snapshot: snapshot),
            staleDate: nil
        )
        guard let requested = try? Activity.request(
            attributes: RunAttributes(sessionID: UUID()),
            content: content,
            pushType: nil
        ) else { return }
        activity = requested
        previous = snapshot
        lastUpdateAt = clock()
    }

    func update(_ snapshot: RunActivitySnapshot) {
        let now = clock()
        guard let activity,
              RunActivityUpdatePolicy.shouldUpdate(
                previous: previous,
                next: snapshot,
                lastUpdateAt: lastUpdateAt,
                now: now
              ) else { return }
        previous = snapshot
        lastUpdateAt = now
        let box = SendableActivityBox(activity: activity)
        Task {
            await box.activity.update(ActivityContent(
                state: RunAttributes.ContentState(snapshot: snapshot),
                staleDate: nil
            ))
        }
    }

    /// CRITICAL 3 fix: called from crash-recovery exits that skip `begin()`
    /// entirely (`AppModel.saveCheckpointedWorkout()` and the resume
    /// prompt's Discard), which is the only place orphan reconciliation
    /// normally runs. Reads `Activity<RunAttributes>.activities` directly —
    /// same as `begin()`'s orphan scan — rather than trusting this
    /// controller's own `activity`, because the surviving activity belongs
    /// to a process that no longer exists; this controller's in-memory
    /// state (freshly `nil` after a relaunch) has no idea it's there.
    func endAllSurvivingActivities() {
        // Mirrors `end()`: invalidate any in-flight deferred request so a
        // `begin()` stray-clearing task that resumes after this call does
        // not turn around and request a brand-new activity for a session
        // that just got torn down.
        requestGate.invalidate()
        activity = nil
        previous = nil
        lastUpdateAt = nil
        let existing = Activity<RunAttributes>.activities
        guard !existing.isEmpty else { return }
        let boxes = existing.map { SendableActivityBox(activity: $0) }
        Task {
            for box in boxes {
                await box.activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func end(_ snapshot: RunActivitySnapshot) {
        // If a `begin()` stray-clearing task is between "strays ended" and
        // "request landed", this run is finishing (or being discarded)
        // before that request lands. Invalidate it so `finishDeferredRequest`
        // bails out WITHOUT calling `Activity.request` at all when it
        // resumes — no activity is ever created for an already-finished
        // session, so there is nothing to leak as an orphan. Harmless
        // no-op when nothing is in flight.
        requestGate.invalidate()
        guard let activity else { return }
        self.activity = nil
        previous = nil
        lastUpdateAt = nil
        let box = SendableActivityBox(activity: activity)
        Task {
            await box.activity.end(
                ActivityContent(
                    state: RunAttributes.ContentState(snapshot: snapshot),
                    staleDate: nil
                ),
                dismissalPolicy: .immediate
            )
        }
    }
}
