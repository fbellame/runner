import Testing
@testable import Runner

struct CalorieEngineTests {
    // MET interpolation clamps at the ends and interpolates in the middle.
    @Test func runMETBreakpointsAndClamp() {
        #expect(abs(CalorieEngine.met(type: .run, speedKmh: 3.0) - 6.0) < 0.001)   // below floor → clamp low
        #expect(abs(CalorieEngine.met(type: .run, speedKmh: 9.7) - 9.8) < 0.001)   // exact breakpoint
        #expect(abs(CalorieEngine.met(type: .run, speedKmh: 40.0) - 19.0) < 0.001) // above top → clamp high
        let mid = CalorieEngine.met(type: .run, speedKmh: 8.85)                    // between 8.0 and 9.7
        #expect(mid > 8.3 && mid < 9.8)
    }

    /// A walk session that stays open while the user stands still used to bill the
    /// 2.0 MET stroll rate for its whole duration, because the table clamped there:
    /// one real auto-walk covering 501 m in 188 minutes claimed 476 kcal. Standing
    /// now costs roughly what standing costs.
    @Test func standingStillDoesNotBillAStrollRate() {
        #expect(abs(CalorieEngine.met(type: .walk, speedKmh: 0.0) - 1.3) < 0.001)
        #expect(CalorieEngine.met(type: .walk, speedKmh: 0.16) < 1.5)
        // 501 m over 188 minutes at 72 kg — the real row.
        let kcal = CalorieEngine.workoutCalories(type: .walk, distanceMeters: 501,
                                                 movingSeconds: 188 * 60, weightKg: 72)
        #expect(kcal < 350)
    }

    @Test func walkAndBikeMET() {
        #expect(abs(CalorieEngine.met(type: .walk, speedKmh: 2.0) - 2.0) < 0.001)  // stroll floor
        #expect(abs(CalorieEngine.met(type: .walk, speedKmh: 5.6) - 4.3) < 0.001)
        #expect(abs(CalorieEngine.met(type: .bike, speedKmh: 10.0) - 4.0) < 0.001) // leisure floor
        #expect(abs(CalorieEngine.met(type: .bike, speedKmh: 22.5) - 10.0) < 0.001)
    }

    // Workout kcal = MET × weightKg × hours. 5 km run in 30 min = 10 km/h.
    @Test func workoutCaloriesRun() {
        let kcal = CalorieEngine.workoutCalories(type: .run, distanceMeters: 5000,
                                                 movingSeconds: 1800, weightKg: 70)
        // 10 km/h → MET ~9.87; 70 kg × 0.5 h → ~345 kcal.
        #expect(kcal > 320 && kcal < 370)
    }

    @Test func workoutCaloriesZeroGuards() {
        #expect(CalorieEngine.workoutCalories(type: .run, distanceMeters: 0, movingSeconds: 0, weightKg: 70) == 0)
        #expect(CalorieEngine.workoutCalories(type: .run, distanceMeters: 3000, movingSeconds: 0, weightKg: 70) == 0)
    }

    // A workout carrying a real Health kcal value uses it verbatim, not the MET math.
    @Test func dayCaloriesPrefersRealKcalWhenPresent() {
        let metrics = BodyMetrics(weightKg: 70, heightCm: 175, sex: .male, age: 30)
        let real = WorkoutEnergyInput(type: .bike, distanceMeters: 5000,
                                      movingSeconds: 1200, realKcal: 42)
        let breakdown = CalorieEngine.dayCalories(steps: 0, workouts: [real], metrics: metrics)
        #expect(breakdown?.workoutKcal == [42])
    }

    @Test func dayCaloriesFallsBackToMETWhenNoRealKcal() {
        let metrics = BodyMetrics(weightKg: 70, heightCm: 175, sex: .male, age: 30)
        let est = WorkoutEnergyInput(type: .run, distanceMeters: 5000, movingSeconds: 1800)
        let breakdown = CalorieEngine.dayCalories(steps: 0, workouts: [est], metrics: metrics)
        let met = CalorieEngine.workoutCalories(type: .run, distanceMeters: 5000,
                                                movingSeconds: 1800, weightKg: 70)
        #expect(breakdown?.workoutKcal.first.map { abs($0 - met) < 0.001 } == true)
    }

    // Stride from height; fallback when height is nil.
    @Test func stride() {
        #expect(abs(CalorieEngine.strideMeters(heightCm: 180, sex: .male) - 0.747) < 0.01)
        #expect(CalorieEngine.strideMeters(heightCm: nil, sex: .female) > 0.6)  // sex-based fallback
        #expect(CalorieEngine.strideMeters(heightCm: nil, sex: .male) > 0.7)
    }

    // No weight → nil (drives the empty state).
    @Test func nilWithoutWeight() {
        let m = BodyMetrics(weightKg: nil, heightCm: 180, sex: .male, age: 30)
        #expect(CalorieEngine.dayCalories(steps: 8000, workouts: [], metrics: m) == nil)
    }

    // Everyday steps are de-duplicated against run/walk workout steps; bike is not subtracted.
    @Test func dayCaloriesDeDuplicatesWorkoutSteps() {
        let m = BodyMetrics(weightKg: 70, heightCm: 180, sex: .male, age: 30)
        let run = WorkoutEnergyInput(type: .run, distanceMeters: 5000, movingSeconds: 1800)
        let withRun = CalorieEngine.dayCalories(steps: 12000, workouts: [run], metrics: m)!
        let stepsOnly = CalorieEngine.dayCalories(steps: 12000, workouts: [], metrics: m)!
        // The run's ~6600 steps are removed from everyday, so everyday kcal drops.
        #expect(withRun.everydayKcal < stepsOnly.everydayKcal)
        #expect(withRun.workoutKcal.count == 1 && withRun.workoutKcal[0] > 300)
        #expect(withRun.everydayKcal >= 0) // never negative

        // A bike ride does NOT subtract steps (no steps produced cycling).
        let bike = WorkoutEnergyInput(type: .bike, distanceMeters: 10000, movingSeconds: 1800)
        let withBike = CalorieEngine.dayCalories(steps: 12000, workouts: [bike], metrics: m)!
        #expect(abs(withBike.everydayKcal - stepsOnly.everydayKcal) < 0.001)
    }

    @Test func totalIsEverydayPlusWorkouts() {
        let m = BodyMetrics(weightKg: 68, heightCm: 172, sex: .female, age: 40)
        let w = WorkoutEnergyInput(type: .walk, distanceMeters: 3000, movingSeconds: 2400)
        let b = CalorieEngine.dayCalories(steps: 9000, workouts: [w], metrics: m)!
        #expect(abs(b.total - (b.everydayKcal + b.workoutKcal.reduce(0, +))) < 0.001)
    }
}
