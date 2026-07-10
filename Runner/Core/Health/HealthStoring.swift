import Foundation
import HealthKit

struct ExternalWorkout: Equatable, Sendable {
    let id: UUID
    let type: ActivityType
    let start: Date
    let end: Date
    let movingSeconds: Double
    let distanceMeters: Double
    let distanceEstimated: Bool
    let activeEnergyKcal: Double?
    let co2SavedGrams: Double?
    let isFromThisApp: Bool

    init(id: UUID, type: ActivityType, start: Date, end: Date, movingSeconds: Double,
         distanceMeters: Double, distanceEstimated: Bool = false,
         activeEnergyKcal: Double? = nil, co2SavedGrams: Double? = nil,
         isFromThisApp: Bool) {
        self.id = id
        self.type = type
        self.start = start
        self.end = end
        self.movingSeconds = movingSeconds
        self.distanceMeters = distanceMeters
        self.distanceEstimated = distanceEstimated
        self.activeEnergyKcal = activeEnergyKcal
        self.co2SavedGrams = co2SavedGrams
        self.isFromThisApp = isFromThisApp
    }
}

struct HealthBody: Sendable {
    let heightCm: Double?
    let weightKg: Double?
    let birthDate: Date?
    let sex: BodySex
}

@MainActor
protocol HealthStoring: AnyObject {
    var isAvailable: Bool { get }
    var writeDenied: Bool { get }
    func requestAuthorization() async throws
    func shouldRequestAuthorization() async -> Bool
    func earliestHistoryDate() async throws -> Date?
    func diagnosticsReport() async -> String
    func dailySteps(daysBack: Int) async throws -> [Date: Int]
    func dailyWalkRunDistance(daysBack: Int) async throws -> [Date: Double]
    /// Walking+running distance over an arbitrary window — used to fill the stretch
    /// of an auto-started walk that happened before GPS was running.
    func walkRunDistance(from: Date, to: Date) async throws -> Double
    func workouts(daysBack: Int) async throws -> [ExternalWorkout]
    func saveWorkout(_ workout: RecordedWorkout, points: Int) async throws -> UUID
    func startObservingSteps(_ onChange: @escaping @Sendable () -> Void)
    func bodyMetrics() async throws -> HealthBody
}
