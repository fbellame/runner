import Testing
@testable import Runner

struct WorkoutEstimationTests {
    @Test func bikeEstimateUsesCityCyclingSpeed() {
        let movingSeconds = 1_800.0
        let meters = WorkoutEstimation.estimatedMeters(type: .bike,
                                                       movingSeconds: movingSeconds)

        #expect(meters == movingSeconds * WorkoutEstimation.cyclingMetersPerSecond)
    }

    @Test func runAndWalkAreNotEstimated() {
        #expect(WorkoutEstimation.estimatedMeters(type: .run, movingSeconds: 1_800) == nil)
        #expect(WorkoutEstimation.estimatedMeters(type: .walk, movingSeconds: 1_800) == nil)
    }

    @Test func nonPositiveDurationIsNotEstimated() {
        #expect(WorkoutEstimation.estimatedMeters(type: .bike, movingSeconds: 0) == nil)
        #expect(WorkoutEstimation.estimatedMeters(type: .bike, movingSeconds: -1) == nil)
    }
}
