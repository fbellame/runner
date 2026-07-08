import Foundation
@testable import Runner

@MainActor
final class FakeHealthStore: HealthStoring {
    var isAvailable = true
    var writeDenied = false
    var stepsByDay: [Date: Int] = [:]
    var cannedWorkouts: [ExternalWorkout] = []
    var earliestHistoryDateStub: Date?
    var saveError: Error?
    var dailyStepsError: Error?
    var workoutsError: Error?
    var earliestHistoryError: Error?
    var savedWorkouts: [(RecordedWorkout, Int)] = []
    var observers: [() -> Void] = []
    var workoutsHook: (() async -> Void)?
    var saveHook: (() async -> Void)?
    var dailyStepsDaysBack: [Int] = []
    var workoutsDaysBack: [Int] = []
    var earliestHistoryDateCalls = 0

    var cannedBody = HealthBody(heightCm: nil, weightKg: nil, birthDate: nil, sex: .unspecified)

    func requestAuthorization() async throws {}
    func shouldRequestAuthorization() async -> Bool { false }
    func bodyMetrics() async throws -> HealthBody { cannedBody }
    func diagnosticsReport() async -> String { "fake" }
    func earliestHistoryDate() async throws -> Date? {
        earliestHistoryDateCalls += 1
        if let earliestHistoryError { throw earliestHistoryError }
        return earliestHistoryDateStub
    }
    func dailySteps(daysBack: Int) async throws -> [Date: Int] {
        dailyStepsDaysBack.append(daysBack)
        if let dailyStepsError { throw dailyStepsError }
        return stepsByDay
    }
    func workouts(daysBack: Int) async throws -> [ExternalWorkout] {
        workoutsDaysBack.append(daysBack)
        await workoutsHook?()
        if let workoutsError { throw workoutsError }
        return cannedWorkouts
    }

    func saveWorkout(_ workout: RecordedWorkout, points: Int) async throws -> UUID {
        await saveHook?()
        if let saveError { throw saveError }
        savedWorkouts.append((workout, points))
        // Mirror real HealthKit visibility: a successful save is immediately
        // returned by subsequent workouts() reads, flagged as ours. Without this,
        // the fake cannot pin the retry-then-recount double-count bug.
        let id = UUID()
        cannedWorkouts.append(ExternalWorkout(id: id, type: workout.type,
                                              start: workout.start,
                                              end: workout.end,
                                              movingSeconds: workout.movingSeconds,
                                              distanceMeters: workout.distanceMeters,
                                              isFromThisApp: true))
        return id
    }

    func startObservingSteps(_ onChange: @escaping @Sendable () -> Void) {
        observers.append(onChange)
    }
}
