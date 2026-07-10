import Foundation
@testable import Runner

@MainActor
final class FakeMotionActivityProvider: MotionActivityProviding {
    var isAvailable = true
    var isAuthorized = true
    var cannedHistory: [MotionSample] = []
    var authorizationRequests = 0
    var started = false
    var stopped = false
    var historyWindows: [(Date, Date)] = []
    private var onSample: ((MotionSample) -> Void)?

    func requestAuthorization() async { authorizationRequests += 1 }

    func startUpdates(_ onSample: @escaping (MotionSample) -> Void) {
        started = true
        self.onSample = onSample
    }

    func stopUpdates() {
        stopped = true
        onSample = nil
    }

    func history(from: Date, to: Date) async -> [MotionSample] {
        historyWindows.append((from, to))
        return isAuthorized ? cannedHistory : []
    }

    /// Drives the live stream from a test.
    func emit(_ sample: MotionSample) { onSample?(sample) }
}
