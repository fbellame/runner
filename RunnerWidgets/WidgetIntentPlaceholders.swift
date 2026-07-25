import AppIntents

struct TogglePauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or resume run"
    func perform() async throws -> some IntentResult { .result() }
}

struct FinishRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Finish run"
    func perform() async throws -> some IntentResult { .result() }
}
