import Foundation

enum Format {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func pace(_ secondsPerKm: Double?) -> String {
        guard let secondsPerKm, secondsPerKm.isFinite, secondsPerKm > 0 else {
            return "—"
        }
        return duration(secondsPerKm) + " /km"
    }

    static func km(_ meters: Double, estimated: Bool = false) -> String {
        let value = meters / 1000.0
        let prefix = estimated ? "~" : ""
        return prefix + value.formatted(.number.precision(.fractionLength(2))) + " km"
    }

    static func kcal(_ value: Double, estimated: Bool = false) -> String {
        let prefix = estimated ? "~" : ""
        return prefix + "\(Int(value.rounded())) kcal"
    }

    static func co2(grams: Double) -> String {
        let kg = grams / 1000.0
        return kg.formatted(.number.precision(.fractionLength(1))) + " kg"
    }
}
