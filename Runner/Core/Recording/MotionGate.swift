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

    mutating func observe(_ sample: MotionSample) { latest = sample }

    /// Dropped when the stream stops, so a classification can never outlive the
    /// subscription that produced it.
    mutating func clear() { latest = nil }

    /// True only on a confident, current "stationary". Every other case —
    /// no sample, unknown, low confidence, stale, or from the future — abstains,
    /// because "we don't know" must never read as "he is standing still".
    func vetoesStart(at time: Date) -> Bool {
        guard let latest, latest.isStationary,
              !latest.isUnknown, !latest.isLowConfidence else { return false }
        let age = time.timeIntervalSince(latest.at)
        return age >= 0 && age <= Self.maxSampleAge
    }
}
