import AppIntents

/// Lock Screen / Live Activity finish control. `LiveActivityIntent` (not
/// plain `AppIntent`) is mandatory here for the same reason as
/// `StartRunIntent`: it runs in the app process, where it can reach
/// `AppModel`, rather than the widget extension.
///
/// This app-target declaration is the real body. `RunnerWidgets` declares a
/// same-named placeholder (`WidgetIntentPlaceholders.swift`) so the widget
/// extension's Live Activity view has a local type to compile against; at
/// runtime iOS matches the intent by type name across the target boundary
/// and runs this implementation in the app process. Both declarations are
/// intentional — do not deduplicate.
struct FinishRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Finish run"

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        await model.finishRunFromIntent()
        return .result()
    }
}
