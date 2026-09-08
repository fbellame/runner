import Foundation

enum StartRunVoiceOutcome: Equatable {
    case started
    case alreadyInProgress
    case silent
}

enum PauseRunVoiceOutcome: Equatable {
    case paused
    case alreadyPaused
    case ready
    case noRun
    case silent
}

enum ResumeRunVoiceOutcome: Equatable {
    case resumed
    case alreadyRunning
    case ready
    case noRun
    case silent
}

enum FinishRunVoiceOutcome: Equatable {
    case saved
    case notStarted
    case noRun
    case saveFailed
    case silent
}

struct RunStatusSnapshot: Equatable {
    enum Phase: Equatable {
        case ready
        case recording
        case paused
    }

    let phase: Phase
    let distanceMeters: Double
    let movingSeconds: Double
    let paceSecondsPerKm: Double?

    func localizedText(locale: Locale = .current) -> String {
        var parts: [String] = []
        switch phase {
        case .ready:
            parts.append(String(localized: "Run ready", locale: locale))
        case .recording:
            break
        case .paused:
            parts.append(String(localized: "Run paused", locale: locale))
        }
        parts.append(Self.distanceText(meters: distanceMeters, locale: locale))
        parts.append(Self.durationText(seconds: movingSeconds, locale: locale))
        parts.append(
            RunAnnouncement.paceText(secondsPerKm: paceSecondsPerKm, locale: locale)
                ?? String(localized: "Pace unavailable", locale: locale)
        )
        return parts.joined(separator: ". ") + "."
    }

    private static func distanceText(meters: Double, locale: Locale) -> String {
        let roundedKilometers = ((max(0, meters) / 1_000) * 10).rounded() / 10
        if roundedKilometers == 1 {
            return String(localized: "1 kilometer", locale: locale)
        }
        let formatted = roundedKilometers.formatted(
            .number.precision(.fractionLength(0...1)).locale(locale)
        )
        return String(localized: "\(formatted) kilometers", locale: locale)
    }

    private static func durationText(seconds: Double, locale: Locale) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let remainingSeconds = total % 60
        if minutes == 0 {
            if remainingSeconds == 1 {
                return String(localized: "1 second", locale: locale)
            }
            return String(localized: "\(remainingSeconds) seconds", locale: locale)
        }
        if remainingSeconds == 0 {
            if minutes == 1 {
                return String(localized: "1 minute", locale: locale)
            }
            return String(localized: "\(minutes) minutes", locale: locale)
        }
        return String(
            localized: "\(minutes) minutes \(remainingSeconds) seconds",
            locale: locale
        )
    }
}

enum RunStatusVoiceOutcome: Equatable {
    case status(RunStatusSnapshot)
    case noRun
    case silent
}
