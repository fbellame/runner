import CoreLocation

/// Answers "how fast is he actually moving right now", which is a different
/// question from "how far apart are the last two fixes".
///
/// Between consecutive 1 Hz fixes, GPS position noise alone is a couple of
/// metres, so a difference-of-positions estimate reads 1-3 m/s while standing
/// perfectly still. Feeding that to `AutoPauseDetector` is what made an armed
/// session start itself at the trailhead and what kept a stopped run from ever
/// auto-pausing. Real movement only dominates the noise over a multi-second
/// baseline, so that is what this measures over — and it re-anchors that
/// baseline continuously, so the estimate describes *now* no matter how long
/// the session has been sitting still.
struct SpeedEstimator {
    /// Below this baseline, noise dominates displacement. At 1.5 m/s (the
    /// run/walk instant-resume speed) 5 s is 7.5 m of travel against ~2-3 m of
    /// noise — the shortest window that still separates the two cleanly.
    static let minBaseline: TimeInterval = 5
    /// Past this the baseline stops describing the present. Letting it grow
    /// without bound is what made a long red light impossible to resume from:
    /// the reference stayed frozen at the last accepted sample, so the divisor
    /// grew for the whole pause and the estimate decayed towards zero.
    static let maxBaseline: TimeInterval = 12

    private var window: [CLLocation] = []

    /// `nil` means "not enough evidence to say" — distinct from "stopped".
    /// The caller must leave the pause/resume accumulators untouched on `nil`;
    /// absence of information is not evidence of stillness.
    mutating func estimate(from location: CLLocation) -> Double? {
        window.removeAll { location.timestamp.timeIntervalSince($0.timestamp) > Self.maxBaseline }
        window.append(location)

        // CoreLocation's own speed is Doppler-derived, not differenced
        // positions, so when the fix carries one it beats anything computable
        // here. It is `-1` when the hardware could not measure it.
        if location.speed >= 0 { return location.speed }

        // Anchor on the NEWEST fix old enough to beat the noise, not the oldest
        // one available. A windowed estimate is a low-pass filter, so every
        // extra second of baseline is an extra second of lag before a stop or a
        // restart shows up — and this profile is deliberately aggressive about
        // both. `maxBaseline` only bounds how stale the anchor may get.
        guard let anchor = window.last(where: {
            location.timestamp.timeIntervalSince($0.timestamp) >= Self.minBaseline
        }) else { return nil }
        let dt = location.timestamp.timeIntervalSince(anchor.timestamp)
        return location.distance(from: anchor) / dt
    }

    mutating func reset() { window.removeAll() }
}
