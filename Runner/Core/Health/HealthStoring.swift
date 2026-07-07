import Foundation
import HealthKit

struct ExternalWorkout: Equatable, Sendable {
    let id: UUID
    let type: ActivityType
    let start: Date
    let end: Date
    let movingSeconds: Double
    let distanceMeters: Double
    let isFromThisApp: Bool
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
    func dailySteps(daysBack: Int) async throws -> [Date: Int]
    func workouts(daysBack: Int) async throws -> [ExternalWorkout]
    func saveWorkout(_ workout: RecordedWorkout, points: Int) async throws -> UUID
    func startObservingSteps(_ onChange: @escaping @Sendable () -> Void)
    func bodyMetrics() async throws -> HealthBody
}
