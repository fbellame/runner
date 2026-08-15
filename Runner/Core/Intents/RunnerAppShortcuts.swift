import AppIntents

struct RunnerAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: VoiceStartRunIntent(),
            phrases: [
                "Start my run with \(.applicationName)",
                "Start a run with \(.applicationName)",
                "Start \(.applicationName)"
            ],
            shortTitle: "Start Run",
            systemImageName: "figure.run"
        )
        AppShortcut(
            intent: PauseRunIntent(),
            phrases: [
                "Pause my run with \(.applicationName)",
                "Pause my \(.applicationName) run",
                "Pause \(.applicationName)"
            ],
            shortTitle: "Pause Run",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumeRunIntent(),
            phrases: [
                "Resume my run with \(.applicationName)",
                "Resume my \(.applicationName) run",
                "Resume \(.applicationName)"
            ],
            shortTitle: "Resume Run",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: VoiceFinishRunIntent(),
            phrases: [
                "Finish my run with \(.applicationName)",
                "Stop my run with \(.applicationName)",
                "Finish my \(.applicationName) run"
            ],
            shortTitle: "Finish Run",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: RunStatusIntent(),
            phrases: [
                "How is my run going in \(.applicationName)",
                "What is my run status in \(.applicationName)",
                "Check my run in \(.applicationName)"
            ],
            shortTitle: "Run Status",
            systemImageName: "speedometer"
        )
    }
}
