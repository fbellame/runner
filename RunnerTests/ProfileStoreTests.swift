import Testing
import Foundation
@testable import Runner

@MainActor
struct ProfileStoreTests {
    private func makeStore() throws -> (DataStore, FakeHealthStore, ProfileStore) {
        let ds = try DataStore(inMemory: true)
        let hs = FakeHealthStore()
        return (ds, hs, ProfileStore(store: ds, health: hs))
    }

    @Test func healthFillsNonManualFields() async throws {
        let (_, hs, ps) = try makeStore()
        hs.cannedBody = HealthBody(heightCm: 178, weightKg: 74,
                                   birthDate: Calendar.current.date(byAdding: .year, value: -34, to: .now),
                                   sex: .male)
        await ps.refreshFromHealth()
        let m = ps.currentMetrics()
        #expect(m.weightKg == 74)
        #expect(m.heightCm == 178)
        #expect(m.sex == .male)
        #expect(m.age == 34)
    }

    @Test func manualOverrideWinsAndSurvivesRefresh() async throws {
        let (_, hs, ps) = try makeStore()
        hs.cannedBody = HealthBody(heightCm: 178, weightKg: 74, birthDate: nil, sex: .male)
        await ps.refreshFromHealth()
        let row = try ps.row()
        row.weightKg = 80
        row.isWeightManual = true
        // A later Health refresh must NOT clobber the manual weight.
        await ps.refreshFromHealth()
        #expect(ps.currentMetrics().weightKg == 80)
        // Non-manual height still tracks Health.
        #expect(ps.currentMetrics().heightCm == 178)
    }

    @Test func nilWhenHealthEmptyAndNoManual() async throws {
        let (_, hs, ps) = try makeStore()
        hs.cannedBody = HealthBody(heightCm: nil, weightKg: nil, birthDate: nil, sex: .unspecified)
        await ps.refreshFromHealth()
        #expect(ps.currentMetrics().weightKg == nil)
    }
}
