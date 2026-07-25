import Testing
import Foundation
@testable import Runner

struct PendingCelebrationPresentationTests {
    @Test func candidateUsesTheRecordedWorkoutValues() {
        let workout = RecordedWorkout(
            type: .run,
            start: Date(timeIntervalSince1970: 1_750_000_000),
            end: Date(timeIntervalSince1970: 1_750_000_600),
            movingSeconds: 600,
            distanceMeters: 5_000,
            route: [],
            splitSeconds: [120, 120, 120, 120, 120]
        )
        let candidate = PendingCelebrationPresentation.candidate(from: workout)

        #expect(candidate.type == .run)
        #expect(candidate.date == workout.start)
        #expect(candidate.distanceMeters == 5_000)
        #expect(candidate.movingSeconds == 600)
        #expect(candidate.splitSeconds == workout.splitSeconds)
    }
}
