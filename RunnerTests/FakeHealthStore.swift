import Foundation
@testable import Runner

@MainActor
final class FakeHealthStore: HealthStoring {
    var isAvailable = true
    var writeDenied = false
    var stepsByDay: [Date: Int] = [:]
    var cannedWorkouts: [ExternalWorkout] = []
    var saveError: Error?
    var savedWorkouts: [(RecordedWorkout, Int)] = []
    var observers: [() -> Void] = []

    func requestAuthorization() async throws {}
    func shouldRequestAuthorization() async -> Bool { false }
    func dailySteps(daysBack: Int) async throws -> [Date: Int] { stepsByDay }
    func workouts(daysBack: Int) async throws -> [ExternalWorkout] { cannedWorkouts }

    func saveWorkout(_ workout: RecordedWorkout, points: Int) async throws -> UUID {
        if let saveError { throw saveError }
        savedWorkouts.append((workout, points))
        return UUID()
    }

    func startObservingSteps(_ onChange: @escaping @Sendable () -> Void) {
        observers.append(onChange)
    }
}
