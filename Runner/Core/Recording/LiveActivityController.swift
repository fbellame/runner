import Foundation
// ActivityKit predates Swift 6 concurrency annotations: `Activity<Attributes>`
// is a plain class with no `Sendable` conformance, and its `update`/`end` are
// nonisolated `async` methods. `@preconcurrency` tells the compiler to trust
// this framework's (unannotated) types across actor boundaries rather than
// enforce full region-based Sendable checking against them — without it,
// `SWIFT_STRICT_CONCURRENCY: complete` refuses to compile any call into
// ActivityKit from this `@MainActor` type.
@preconcurrency import ActivityKit

// Retroactive `ActivityAttributes` conformance for `RunAttributes`, added here
// (rather than in Task 7's `RunAttributes.swift`) so that file — and therefore
// the test target — never has to `import ActivityKit`. This is the one file
// allowed to talk to the real framework.
extension RunAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        let snapshot: RunActivitySnapshot
    }
}

// `Codable` can only be synthesized by the compiler from an extension that
// lives in the same file as the type it extends — `RunAttributes` itself is
// declared in `RunAttributes.swift`, so that synthesis doesn't reach here.
// Implemented by hand instead of moving/duplicating the type.
extension RunAttributes: Codable {
    private enum CodingKeys: String, CodingKey { case sessionID }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sessionID: try container.decode(UUID.self, forKey: .sessionID))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
    }
}

/// The real `LiveActivityPresenting` implementation: owns the single
/// `Activity<RunAttributes>` for the run currently on screen and talks to
/// ActivityKit. Every ActivityKit call that requires `await` is hopped onto
/// its own `Task` so `begin`/`update`/`end` stay synchronous — callers
/// (`WorkoutRecorder`'s hot path) must never suspend.
@MainActor
final class LiveActivityController: LiveActivityPresenting {
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
        Task {
            await activity.update(ActivityContent(
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
        Task {
            await activity.end(
                ActivityContent(
                    state: RunAttributes.ContentState(snapshot: snapshot),
                    staleDate: nil
                ),
                dismissalPolicy: .immediate
            )
        }
    }
}
