import Testing
@testable import Runner

@MainActor
struct RunAnnouncerTests {
    private final class Spoken: @unchecked Sendable {
        var values: [String] = []
    }

    @Test func emitsTheExactLocalizedTextWithoutPlayingAudio() {
        let spoken = Spoken()
        let announcer = RunAnnouncer { spoken.values.append($0) }

        announcer.announce(.runStarted)
        announcer.announce(.paused)
        announcer.announce(.resumed)
        announcer.announce(.runSaved)
        announcer.announce(.runCancelled)
        announcer.announce(.locationDenied)

        #expect(spoken.values == [
            String(localized: "Run started"),
            String(localized: "Paused"),
            String(localized: "Resumed"),
            String(localized: "Run saved"),
            String(localized: "Run cancelled"),
            String(localized: "Location access is required")
        ])
    }
}

@MainActor
struct SpeechSessionTrackerTests {
    private final class FakeAudioSession: AudioSessionControlling, @unchecked Sendable {
        var activateCount = 0
        var deactivateCount = 0

        func activate() { activateCount += 1 }
        func deactivate() { deactivateCount += 1 }
    }

    @Test func deactivatesOnceTheOnlyPendingUtteranceEnds() {
        let session = FakeAudioSession()
        let tracker = SpeechSessionTracker(audioSession: session)

        tracker.utteranceQueued()
        #expect(session.activateCount == 1)
        #expect(session.deactivateCount == 0)

        tracker.utteranceEnded()
        #expect(session.deactivateCount == 1)
    }

    @Test func doesNotDeactivateBetweenTwoOverlappingUtterances() {
        let session = FakeAudioSession()
        let tracker = SpeechSessionTracker(audioSession: session)

        tracker.utteranceQueued() // first cue starts speaking
        tracker.utteranceQueued() // second cue queued while the first is still speaking
        #expect(session.activateCount == 2)

        tracker.utteranceEnded() // first cue finishes — second still pending
        #expect(session.deactivateCount == 0)

        tracker.utteranceEnded() // second cue finishes — nothing left pending
        #expect(session.deactivateCount == 1)
    }

    @Test func cancellingAnUtteranceCountsAsEndingItToo() {
        let session = FakeAudioSession()
        let tracker = SpeechSessionTracker(audioSession: session)

        tracker.utteranceQueued()
        tracker.utteranceEnded() // stands in for a didCancel callback — same bookkeeping as didFinish
        #expect(session.deactivateCount == 1)
    }
}
