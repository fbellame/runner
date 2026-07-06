import CoreLocation

enum LocationFilter {
    static let maxHorizontalAccuracy: Double = 30
    static let maxSampleAge: TimeInterval = 10
    static let minDisplacementMeters: Double = 3
    static let gapSeconds: TimeInterval = 15

    struct Decision: Equatable {
        let accepted: Bool
        let afterGap: Bool
    }

    static func evaluate(candidate: CLLocation, lastKept: CLLocation?, now: Date) -> Decision {
        let reject = Decision(accepted: false, afterGap: false)
        guard candidate.horizontalAccuracy >= 0,
              candidate.horizontalAccuracy <= maxHorizontalAccuracy else { return reject }
        guard now.timeIntervalSince(candidate.timestamp) <= maxSampleAge else { return reject }

        guard let last = lastKept else {
            return Decision(accepted: true, afterGap: false)
        }
        guard candidate.distance(from: last) >= minDisplacementMeters else { return reject }
        let afterGap = candidate.timestamp.timeIntervalSince(last.timestamp) > gapSeconds
        return Decision(accepted: true, afterGap: afterGap)
    }
}
