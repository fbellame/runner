import AppIntents

struct TogglePauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or resume run"
    func perform() async throws -> some IntentResult { .result() }
}

struct FinishRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Finish run"
    func perform() async throws -> some IntentResult { .result() }
}

/// Placeholder body for the widget extension's local type. `ControlWidgetButton`
/// needs this type to compile against in this target; at runtime iOS matches
/// `StartRunIntent` by type name across the target boundary and runs the
/// app-target implementation (`Runner/Core/Intents/StartRunIntent.swift`) in the
/// app process instead. Same name and `LiveActivityIntent` conformance on
/// purpose — do not deduplicate or delete either copy.
struct StartRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Run"
    func perform() async throws -> some IntentResult { .result() }
}
