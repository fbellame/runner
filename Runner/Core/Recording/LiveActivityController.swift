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

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    func begin(_ snapshot: RunActivitySnapshot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              activity == nil else { return }

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

        // Any non-matching stray is dead weight on the lock screen (or, in
        // the non-matching case, belongs to a different run entirely) and
        // is ended. More than one stray can exist after repeated
        // crash/relaunch cycles.
        for index in decision.endIndices {
            let box = SendableActivityBox(activity: existing[index])
            Task { await box.activity.end(nil, dismissalPolicy: .immediate) }
        }

        if let adoptIndex = decision.adoptIndex {
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

        let content = ActivityContent(
            state: RunAttributes.ContentState(snapshot: snapshot),
            staleDate: nil
        )
        activity = try? Activity.request(
            attributes: RunAttributes(sessionID: UUID()),
            content: content,
            pushType: nil
        )
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

    func end(_ snapshot: RunActivitySnapshot) {
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
