import Foundation

/// Best-effort reader for a workout's CO₂-avoided metadata (Bixi writes a custom
/// key; HealthKit has no standard CO₂ type). Heuristic + unit-guess; callers fall
/// back to `CO2Estimator` when this returns nil, so a changed Bixi schema degrades
/// gracefully instead of breaking. Pure — testable with a plain dictionary.
enum Co2Metadata {
    /// Below this the value is assumed to be kilograms rather than grams.
    static let kgThreshold = 100.0

    static func grams(from metadata: [String: Any]?) -> Double? {
        guard let metadata else { return nil }
        let match = metadata.first { key, _ in
            let k = key.lowercased()
            return k.contains("co2") || k.contains("carbon")
        }
        guard let value = match?.value else { return nil }

        let number: Double?
        switch value {
        case let n as NSNumber: number = n.doubleValue
        case let s as String: number = Double(s)
        default: number = nil
        }
        guard let number, number > 0 else { return nil }
        return number < kgThreshold ? number * 1000.0 : number
    }
}
