import CoreMotion
import Foundation

@MainActor
final class SystemMotionActivityProvider: MotionActivityProviding {
    private let manager = CMMotionActivityManager()
    private let queue = OperationQueue.main
    private var isUpdating = false

    var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    var isAuthorized: Bool {
        CMMotionActivityManager.authorizationStatus() == .authorized
    }

    /// There is no explicit request API: the prompt appears on first query, and
    /// the status only settles once that query returns. A one-second lookback is
    /// the cheapest way to trigger it.
    func requestAuthorization() async {
        guard isAvailable else { return }
        _ = await history(from: Date().addingTimeInterval(-1), to: Date())
    }

    func startUpdates(_ onSample: @escaping (MotionSample) -> Void) {
        guard isAvailable, !isUpdating else { return }
        isUpdating = true
        // The queue is main, so the handler already runs on the main actor.
        manager.startActivityUpdates(to: queue) { activity in
            guard let activity else { return }
            let sample = Self.sample(from: activity)
            MainActor.assumeIsolated { onSample(sample) }
        }
    }

    func stopUpdates() {
        guard isUpdating else { return }
        isUpdating = false
        manager.stopActivityUpdates()
    }

    func history(from: Date, to: Date) async -> [MotionSample] {
        guard isAvailable else { return [] }
        return await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: from, to: to, to: queue) { activities, _ in
                continuation.resume(returning: (activities ?? []).map(Self.sample(from:)))
            }
        }
    }

    /// CoreMotion sets flags rather than an enum, and can set none at all.
    /// Anything that isn't a confident walking classification stays unknown, so
    /// the detector never mistakes a cycling or automotive stretch for stillness.
    nonisolated static func sample(from activity: CMMotionActivity) -> MotionSample {
        let classified = activity.walking || activity.running || activity.cycling
            || activity.automotive || activity.stationary
        return MotionSample(isWalking: activity.walking,
                            isUnknown: activity.unknown || !classified,
                            isLowConfidence: activity.confidence == .low,
                            isStationary: activity.stationary,
                            at: activity.startDate)
    }
}
