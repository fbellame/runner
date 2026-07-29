import Testing
import Foundation
import CoreLocation
import AppIntents
@testable import Runner

@MainActor
struct RunVoiceControlTests {
    private final class AnnouncementSpy: Announcing {
        var events: [RunAnnouncement] = []
        func announce(_ event: RunAnnouncement) { events.append(event) }
    }

    private func makeModel(
        clock: @escaping () -> Date = { Date() }
    ) throws -> (AppModel, AnnouncementSpy) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-control-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(directory: directory)
        let announcements = AnnouncementSpy()
        return (
            AppModel(
                store: try DataStore(inMemory: true),
                health: FakeHealthStore(),
                recorder: WorkoutRecorder(
                    provider: FakeLocationProvider(),
                    checkpoints: checkpoints,
                    clock: clock,
                    announcer: announcements
                ),
                checkpoints: checkpoints,
                pendingCelebrations: PendingCelebrationStore(directory: directory)
            ),
            announcements
        )
    }

    @Test func explicitPauseAndResumeNeverToggleTheOppositeWay() throws {
        let (model, announcements) = try makeModel()
        model.recorder.start(activity: .run)

        #expect(model.pauseRunFromIntent(announcing: false) == .paused)
        #expect(model.recorder.state == .manuallyPaused)
        #expect(model.pauseRunFromIntent(announcing: false) == .alreadyPaused)
        #expect(model.recorder.state == .manuallyPaused)

        #expect(model.resumeRunFromIntent(announcing: false) == .resumed)
        #expect(model.recorder.state == .recording)
        #expect(model.resumeRunFromIntent(announcing: false) == .alreadyRunning)
        #expect(model.recorder.state == .recording)
        #expect(announcements.events.isEmpty)
    }

    @Test func voiceStartSuppressesOnlyTheLaterArmedStartCue() throws {
        let base = Date().addingTimeInterval(-4)
        let (model, announcements) = try makeModel(clock: { base })
        #expect(model.startRunFromIntent(announcesStartOnMovement: false) == .started)

        func location(x: Double, seconds: TimeInterval) -> CLLocation {
            let longitude = -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180))
            return CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 45.5, longitude: longitude),
                altitude: 30,
                horizontalAccuracy: 5,
                verticalAccuracy: 10,
                course: 90,
                speed: 2,
                timestamp: base.addingTimeInterval(seconds)
            )
        }
        model.recorder.didUpdate(locations: [
            location(x: 0, seconds: 0),
            location(x: 5, seconds: 3)
        ])

        #expect(model.recorder.state == .recording)
        #expect(announcements.events.isEmpty)
    }

    @Test func voiceFinishSavesWithoutTheRecorderSpeakingToo() async throws {
        let (model, announcements) = try makeModel()
        let end = Date()
        let checkpoint = SessionCheckpoint(
            activity: .run,
            startedAt: end.addingTimeInterval(-600),
            movingSeconds: 600,
            distanceMeters: 2_000,
            route: [
                RoutePoint(lat: 45.5, lon: -73.6, t: end, afterGap: false)
            ],
            splitSeconds: [300, 300],
            savedAt: end
        )
        try model.checkpoints.save(checkpoint)

        #expect(await model.finishRunFromIntent(announcingSaved: false) == .saved)

        #expect(try model.store.allWorkouts().count == 1)
        #expect(announcements.events.isEmpty)
    }

    @Test func statusUsesSpeechFriendlyDistanceDurationAndPace() {
        let status = RunStatusSnapshot(
            phase: .recording,
            distanceMeters: 3_400,
            movingSeconds: 1_080,
            paceSecondsPerKm: 322
        )

        // Foundation resolves the string table from the bundle's own
        // localization, not from this `locale:` — that argument only drives
        // number formatting. Asserting one language's exact wording therefore
        // passes or fails depending on what language the *simulator* is set
        // to, which is not a property of this code. Assert what must hold in
        // every language instead.
        let en = status.localizedText(locale: Locale(identifier: "en"))
        let fr = status.localizedText(locale: Locale(identifier: "fr"))
        #expect(en.contains("3.4"))   // decimal separator follows the locale
        #expect(fr.contains("3,4"))
        for text in [en, fr] {
            #expect(text.contains("18"))              // minutes elapsed
            #expect(text.contains("5"))               // pace minutes
            #expect(text.contains("22"))              // pace seconds
            #expect(text.contains("5:22") == false)   // never the visual form
        }
    }

    @Test func statusWorksWhileArmedPausedAndRecoveredFromCheckpoint() throws {
        let (idleModel, _) = try makeModel()
        #expect(idleModel.runStatusFromIntent() == .noRun)

        let (armedModel, _) = try makeModel()
        armedModel.startRunFromIntent()
        let armed = armedModel.runStatusFromIntent()
        #expect(
            armed == .status(
                RunStatusSnapshot(
                    phase: .ready,
                    distanceMeters: 0,
                    movingSeconds: 0,
                    paceSecondsPerKm: nil
                )
            )
        )

        let (pausedModel, _) = try makeModel()
        pausedModel.recorder.start(activity: .run)
        pausedModel.recorder.pauseManually()
        guard case .status(let paused) = pausedModel.runStatusFromIntent() else {
            Issue.record("Expected a paused run status")
            return
        }
        #expect(paused.phase == .paused)

        let (recoveredModel, _) = try makeModel()
        let savedAt = Date().addingTimeInterval(-30)
        try recoveredModel.checkpoints.save(
            SessionCheckpoint(
                activity: .run,
                startedAt: savedAt.addingTimeInterval(-570),
                movingSeconds: 570,
                distanceMeters: 2_400,
                route: [
                    RoutePoint(
                        lat: 45.5,
                        lon: -73.6,
                        t: savedAt,
                        afterGap: false
                    )
                ],
                splitSeconds: [280, 285],
                savedAt: savedAt,
                isPaused: true
            )
        )
        guard case .status(let recovered) = recoveredModel.runStatusFromIntent() else {
            Issue.record("Expected a recovered run status")
            return
        }
        #expect(recovered.phase == .paused)
        #expect(recovered.distanceMeters == 2_400)
        #expect(recoveredModel.pendingResume == nil)
    }

    @Test func voiceFinishReportsFailureWithoutClaimingTheRunWasSaved() async throws {
        let (model, announcements) = try makeModel()
        let savedAt = Date().addingTimeInterval(-30)
        try model.checkpoints.save(
            SessionCheckpoint(
                activity: .run,
                startedAt: savedAt.addingTimeInterval(-570),
                movingSeconds: 570,
                distanceMeters: 2_400,
                route: [
                    RoutePoint(
                        lat: 45.5,
                        lon: -73.6,
                        t: savedAt,
                        afterGap: false
                    )
                ],
                splitSeconds: [280, 285],
                savedAt: savedAt
            )
        )
        model.store.upsertFailureForTesting = NSError(
            domain: "SwiftData",
            code: 13
        )

        #expect(await model.finishRunFromIntent(announcingSaved: false) == .saveFailed)
        #expect(model.checkpoints.load() != nil)
        #expect(announcements.events.isEmpty)
    }

    @Test func everyNewVoiceSurfaceStaysSilentForAnAutoDetectedWalk() async throws {
        let (model, announcements) = try makeModel()
        model.recorder.start(
            activity: .walk,
            backdatedTo: Date().addingTimeInterval(-300),
            autoStarted: true
        )

        #expect(model.startRunFromIntent() == .silent)
        #expect(model.pauseRunFromIntent() == .silent)
        #expect(model.resumeRunFromIntent() == .silent)
        #expect(model.runStatusFromIntent() == .silent)
        #expect(await model.finishRunFromIntent() == .silent)
        #expect(model.recorder.state != .idle)
        #expect(announcements.events.isEmpty)
    }

    @Test func providerDeclaresFiveLockedBackgroundShortcuts() {
        #expect(RunnerAppShortcuts.appShortcuts.count == 5)
        #expect(VoiceStartRunIntent.authenticationPolicy == .alwaysAllowed)
        #expect(PauseRunIntent.authenticationPolicy == .alwaysAllowed)
        #expect(ResumeRunIntent.authenticationPolicy == .alwaysAllowed)
        #expect(VoiceFinishRunIntent.authenticationPolicy == .alwaysAllowed)
        #expect(RunStatusIntent.authenticationPolicy == .alwaysAllowed)
        #expect(VoiceStartRunIntent.openAppWhenRun == false)
        #expect(PauseRunIntent.openAppWhenRun == false)
        #expect(ResumeRunIntent.openAppWhenRun == false)
        #expect(VoiceFinishRunIntent.openAppWhenRun == false)
        #expect(RunStatusIntent.openAppWhenRun == false)
    }
}
