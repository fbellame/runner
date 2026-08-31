import Foundation

/// A second opinion on "is he actually moving", from the motion coprocessor
/// rather than from GPS.
///
/// GPS is the only sensor the auto-pause machinery ever consulted, and GPS has
/// one failure mode it cannot detect from the inside: a signal bouncing off a
/// building reads as genuine travel. That is what started a run while Farid was
/// still standing at the trailhead. Step counting has no such failure mode — a
/// phone that is not moving produces no steps, however confused its fix is.
///
/// The gate is deliberately **one-directional: it can only refuse to start or
/// resume a run, never cause or delay a pause.** A pause veto would be the more
/// obvious symmetry, but `CMMotionActivity` lags a real transition by seconds,
/// so a stale "walking" classification could hold a stopped run open — which is
/// precisely the bug this whole round was about. Stopping stays GPS's job.
struct MotionGate {
    /// A classification stays true until the coprocessor reports a change, so
    /// there is no natural expiry — a five-minute stand still produces one
    /// sample. This is only a backstop against a stream that has died: past it
    /// the gate abstains rather than blocking a start forever.
    static let maxSampleAge: TimeInterval = 300

    private var latest: MotionSample?

    /// Newest wins. The recorder seeds the gate by replaying CoreMotion history
    /// while the live stream is already attached, so samples can arrive out of
    /// order; without this an old replayed classification could overwrite a
    /// fresher live one.
    mutating func observe(_ sample: MotionSample) {
        if let latest, sample.at <= latest.at { return }
        latest = sample
    }

    /// Dropped when the stream stops, so a classification can never outlive the
    /// subscription that produced it.
    mutating func clear() { latest = nil }

    /// True only on a confident, current "stationary". Every other case —
    /// no sample, unknown, low confidence, stale, or from the future — abstains,
    /// because "we don't know" must never read as "he is standing still".
    func vetoesStart(at time: Date) -> Bool {
        reason(at: time) == .stationary
    }

    /// Why the gate answered the way it did. `vetoesStart` collapses all five
    /// outcomes into one Bool, which is the right shape for the state machine and
    /// the wrong shape for a trace: seven real sessions logged 8760 samples that
    /// all said "no veto" without ever saying whether that meant "he is moving" or
    /// "CoreMotion never sent us anything". `SessionTrace` records this instead.
    enum Reason: String {
        case noSample = ""
        case unknown
        case lowConfidence = "lowconf"
        case stale
        case moving
        case stationary
    }

    func reason(at time: Date) -> Reason {
        guard let latest else { return .noSample }
        if latest.isUnknown { return .unknown }
        if latest.isLowConfidence { return .lowConfidence }
        let age = time.timeIntervalSince(latest.at)
        guard age >= 0, age <= Self.maxSampleAge else { return .stale }
        return latest.isStationary ? .stationary : .moving
    }
}
