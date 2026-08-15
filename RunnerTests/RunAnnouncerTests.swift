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

    /// The first kilometre's split IS the run's pace, so naming both would be
    /// noise. It keeps the plain single-pace wording.
    @Test func firstKilometerAnnouncesASinglePace() {
        #expect(RunAnnouncement.kmSplit(km: 1, splitSeconds: 342, averageSecondsPerKm: 342).localizedText
                == "\(String(localized: "1 kilometer")). \(String(localized: "Pace \(5) minutes \(42) per kilometer")).")
    }

    /// From the second kilometre, one number is misleading: "2 kilometres.
    /// Pace 5 minutes 38" sounds like the pace of the whole run when it is
    /// only that kilometre's. Both are spoken, and each is named.
    @Test func laterKilometersAnnounceSplitAndAveragePaceSeparatelyNamed() {
        #expect(RunAnnouncement.kmSplit(km: 2, splitSeconds: 338, averageSecondsPerKm: 350).localizedText
                == "\(String(localized: "\(2) kilometers")). "
                 + "\(String(localized: "Last kilometer \(5) minutes \(38)")). "
                 + "\(String(localized: "Average \(5) minutes \(50) per kilometer")).")
    }

    @Test func exactMinutePacesDropTheZeroSecondsInBothPositions() {
        #expect(RunAnnouncement.kmSplit(km: 3, splitSeconds: 300, averageSecondsPerKm: 360).localizedText
                == "\(String(localized: "\(3) kilometers")). "
                 + "\(String(localized: "Last kilometer \(5) minutes")). "
                 + "\(String(localized: "Average \(6) minutes per kilometer")).")
    }

    /// A missing average must not swallow the split that IS available.
    @Test func laterKilometerFallsBackToTheSplitAloneWithoutAnAverage() {
        #expect(RunAnnouncement.kmSplit(km: 2, splitSeconds: 338, averageSecondsPerKm: nil).localizedText
                == "\(String(localized: "\(2) kilometers")). "
                 + "\(String(localized: "Last kilometer \(5) minutes \(38)")).")
    }

    @Test func kmSplitOmitsPaceForZeroOrNegativeSplit() {
        let distance = String(localized: "\(4) kilometers")
        #expect(RunAnnouncement.kmSplit(km: 4, splitSeconds: 0, averageSecondsPerKm: 330).localizedText == "\(distance).")
        #expect(RunAnnouncement.kmSplit(km: 4, splitSeconds: -1, averageSecondsPerKm: 330).localizedText == "\(distance).")
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
