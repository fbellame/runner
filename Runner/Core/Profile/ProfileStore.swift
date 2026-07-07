import Foundation

@MainActor
final class ProfileStore {
    private let store: DataStore
    private let health: HealthStoring

    init(store: DataStore, health: HealthStoring) {
        self.store = store
        self.health = health
    }

    func row() throws -> UserProfile { try store.profile() }

    func currentMetrics() -> BodyMetrics {
        (try? store.profile())?.bodyMetrics
            ?? BodyMetrics(weightKg: nil, heightCm: nil, sex: .unspecified, age: nil)
    }

    /// Pull raw Health values into every field the user hasn't manually pinned.
    func refreshFromHealth() async {
        guard let body = try? await health.bodyMetrics(), let profile = try? store.profile() else { return }
        if !profile.isHeightManual, let h = body.heightCm { profile.heightCm = h }
        if !profile.isWeightManual, let w = body.weightKg { profile.weightKg = w }
        if !profile.isBirthManual, let b = body.birthDate { profile.birthDate = b }
        if !profile.isSexManual, body.sex != .unspecified { profile.sex = body.sex }
        try? store.save()
    }
}
