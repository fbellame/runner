import Foundation

/// One classification of what the user was doing at a moment in time.
/// `isUnknown` and `isLowConfidence` are kept distinct from `isWalking == false`:
/// "we don't know" must never be read as "not walking".
struct MotionSample: Equatable, Sendable {
    let isWalking: Bool
    let isUnknown: Bool
    let isLowConfidence: Bool
    /// The coprocessor's own "not going anywhere". Unlike GPS, this cannot be
    /// fooled by a signal bouncing off a building, which is what `MotionGate`
    /// uses it for. Defaulted so the walk-detection call sites, which have no
    /// interest in it, stay as they were.
    let isStationary: Bool
    let at: Date

    init(isWalking: Bool, isUnknown: Bool, isLowConfidence: Bool,
         isStationary: Bool = false, at: Date) {
        self.isWalking = isWalking
        self.isUnknown = isUnknown
        self.isLowConfidence = isLowConfidence
        self.isStationary = isStationary
        self.at = at
    }
}

/// A seam over `CMMotionActivityManager`, mirroring `LocationProviding`.
/// The system implementation is the only file in the project that imports CoreMotion.
@MainActor
protocol MotionActivityProviding: AnyObject {
    var isAvailable: Bool { get }
    var isAuthorized: Bool { get }
    func requestAuthorization() async
    func startUpdates(_ onSample: @escaping (MotionSample) -> Void)
    func stopUpdates()
    /// Whatever the motion coprocessor logged in the window; may be sparser than
    /// the live stream, and empty when unauthorized.
    func history(from: Date, to: Date) async -> [MotionSample]
}
