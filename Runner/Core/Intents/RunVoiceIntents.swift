import AppIntents

/// Siri-facing intents stay separate from the same-process Live Activity
/// button intents. Both need `LiveActivityIntent` so iOS runs them in Runner's
/// process, where `AppModel` is registered, and can background-launch that
/// process without opening or unlocking the app. Keeping separate types lets
/// Siri provide the voice reply while Lock Screen button taps retain the
/// recorder's existing AVSpeechSynthesizer confirmation.
struct VoiceStartRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Run"
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = model.startRunFromIntent(announcesStartOnMovement: false)
        let dialog: IntentDialog = switch outcome {
        case .started: "Run started"
        case .alreadyInProgress: "A run is already in progress"
        case .silent: IntentDialog(LocalizedStringResource(stringLiteral: ""))
        }
        return .result(dialog: dialog)
    }
}

struct PauseRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause Run"
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = model.pauseRunFromIntent(announcing: false)
        let dialog: IntentDialog = switch outcome {
        case .paused: "Run paused"
        case .alreadyPaused: "Run is already paused"
        case .ready: "Run has not started yet"
        case .noRun: "No run in progress"
        case .silent: IntentDialog(LocalizedStringResource(stringLiteral: ""))
        }
        return .result(dialog: dialog)
    }
}

struct ResumeRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume Run"
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = model.resumeRunFromIntent(announcing: false)
        let dialog: IntentDialog = switch outcome {
        case .resumed: "Run resumed"
        case .alreadyRunning: "Run is already in progress"
        case .waitingForMovement: "Run will resume when you start moving"
        case .ready: "Run has not started yet"
        case .noRun: "No run in progress"
        case .silent: IntentDialog(LocalizedStringResource(stringLiteral: ""))
        }
        return .result(dialog: dialog)
    }
}

struct VoiceFinishRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Finish Run"
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await model.finishRunFromIntent(announcingSaved: false)
        let dialog: IntentDialog = switch outcome {
        case .saved: "Run saved"
        case .notStarted: "Run has not started yet"
        case .noRun: "No run in progress"
        case .saveFailed: "Run could not be saved"
        case .silent: IntentDialog(LocalizedStringResource(stringLiteral: ""))
        }
        return .result(dialog: dialog)
    }
}

struct RunStatusIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Check Run Status"
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = model.runStatusFromIntent()
        let dialog: IntentDialog = switch outcome {
        case .status(let status):
            IntentDialog(
                LocalizedStringResource(
                    stringLiteral: status.localizedText()
                )
            )
        case .noRun:
            "No run in progress"
        case .silent:
            IntentDialog(LocalizedStringResource(stringLiteral: ""))
        }
        return .result(dialog: dialog)
    }
}
