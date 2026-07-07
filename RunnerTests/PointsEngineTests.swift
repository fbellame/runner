import Testing
@testable import Runner

struct PointsEngineTests {
    // Steps: floor(steps/100), cap 200
    @Test(arguments: [
        (0, 0), (99, 0), (100, 1), (8_450, 84), (19_999, 199), (20_000, 200), (55_000, 200),
    ])
    func stepPoints(steps: Int, expected: Int) {
        #expect(PointsEngine.stepPoints(steps: steps) == expected)
    }

    // Workouts: round(km × rate)
    @Test func workoutPointsPerType() {
        #expect(PointsEngine.workoutPoints(type: .run, distanceMeters: 2_100) == 32)   // 2.1×15=31.5 → 32
        #expect(PointsEngine.workoutPoints(type: .walk, distanceMeters: 2_100) == 21)  // 2.1×10=21
        #expect(PointsEngine.workoutPoints(type: .bike, distanceMeters: 10_000) == 60) // 10×6=60
        #expect(PointsEngine.workoutPoints(type: .run, distanceMeters: 0) == 0)
        #expect(PointsEngine.workoutPoints(type: .bike, distanceMeters: 8_249) == 49)  // 8.249×6=49.494 → 49
    }

    // Multiplier: min(1 + 0.05n, 1.5); n = gold days BEFORE today
    @Test(arguments: [
        (0, 1.0), (1, 1.05), (4, 1.2), (9, 1.45), (10, 1.5), (11, 1.5), (400, 1.5),
    ])
    func multiplier(streak: Int, expected: Double) {
        #expect(abs(PointsEngine.multiplier(streakBefore: streak) - expected) < 0.0001)
    }

    // Total: round((stepPts + workoutPts) × multiplier)
    @Test func breakdownComposition() {
        let b = PointsEngine.breakdown(
            steps: 8_450,
            workouts: [WorkoutSummary(type: .run, distanceMeters: 2_100)],
            streakBefore: 4
        )
        #expect(b.stepPoints == 84)
        #expect(b.workoutPoints == 32)
        #expect(abs(b.multiplier - 1.2) < 0.0001)
        #expect(b.total == 139) // (84+32)×1.2 = 139.2 → 139
    }

    @Test func breakdownEmptyDay() {
        let b = PointsEngine.breakdown(steps: 0, workouts: [], streakBefore: 0)
        #expect(b == PointsBreakdown(stepPoints: 0, workoutPoints: 0, multiplier: 1.0, total: 0))
    }

    @Test func breakdownMultipleWorkouts() {
        let b = PointsEngine.breakdown(
            steps: 1_000,
            workouts: [
                WorkoutSummary(type: .run, distanceMeters: 5_000),   // 75
                WorkoutSummary(type: .bike, distanceMeters: 12_000), // 72
            ],
            streakBefore: 0
        )
        #expect(b.workoutPoints == 147)
        #expect(b.total == 157) // (10+147)×1.0
    }

    // Live HUD shows exactly what the summary would award at this distance —
    // no +1 jump the moment the user slides to finish.
    @Test func livePointsMatchesWorkoutPoints() {
        #expect(PointsEngine.livePoints(type: .run, distanceMeters: 2_970) ==
                PointsEngine.workoutPoints(type: .run, distanceMeters: 2_970)) // 44.55 → 45
        #expect(PointsEngine.livePoints(type: .run, distanceMeters: 2_100) == 32)  // 31.5 → 32
        #expect(PointsEngine.livePoints(type: .walk, distanceMeters: 999) == 10)   // 9.99 → 10
        #expect(PointsEngine.livePoints(type: .run, distanceMeters: 0) == 0)
    }
}
