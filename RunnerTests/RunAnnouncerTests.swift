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
