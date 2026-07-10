import Foundation

final class TrophySeenStore {
    private static let key = "trophySeenBadgeIDs_v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isSeen(_ id: String) -> Bool {
        seenIDs.contains(id)
    }

    func markSeen(_ ids: [String]) {
        defaults.set(Array(seenIDs.union(ids)), forKey: Self.key)
    }

    private var seenIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }
}
