import AppIntents

/// Lock Screen / Control Center entry point for arming a run without
/// unlocking the phone. `LiveActivityIntent` (not plain `AppIntent`) is
/// mandatory here: it runs in the app process and may background-launch
/// Runner, which a plain `AppIntent` running in the widget extension could
/// never do — that process can't reach `AppModel`.
///
/// This app-target declaration is the real body. `RunnerWidgets` declares a
/// same-named placeholder (`WidgetIntentPlaceholders.swift`) so the widget
/// extension's `ControlWidgetButton` has a local type to compile against;
/// at runtime iOS matches the intent by type name across the target
/// boundary and runs this implementation in the app process. Both
/// declarations are intentional — do not deduplicate.
struct StartRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Run"

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        model.startRunFromIntent()
        return .result()
    }
}
