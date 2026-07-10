import Foundation

final class WrappedSeenStore {
    private static let key = "wrappedSeenMonths_v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isSeen(_ month: WrappedMonth) -> Bool {
        seenMonths.contains(month.key)
    }

    func markSeen(_ month: WrappedMonth) {
        defaults.set(Array(seenMonths.union([month.key])), forKey: Self.key)
    }

    private var seenMonths: Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }
}

private extension WrappedMonth {
    var key: String { "\(year)-\(month)" }
}
