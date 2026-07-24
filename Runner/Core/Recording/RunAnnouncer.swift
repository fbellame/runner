import Foundation
import AVFoundation

enum RunAnnouncement: Equatable, Sendable {
    case runStarted
    case paused
    case resumed
    case runSaved
    case runCancelled
    case locationDenied

    var localizedText: String {
        switch self {
        case .runStarted: String(localized: "Run started")
        case .paused: String(localized: "Paused")
        case .resumed: String(localized: "Resumed")
        case .runSaved: String(localized: "Run saved")
        case .runCancelled: String(localized: "Run cancelled")
        case .locationDenied: String(localized: "Location access is required")
        }
    }
}

@MainActor
protocol Announcing: Sendable {
    func announce(_ event: RunAnnouncement)
}

@MainActor
final class RunAnnouncer: Announcing {
    private let synthesizer = AVSpeechSynthesizer()
    private let sink: (@MainActor @Sendable (String) -> Void)?

    init(sink: (@MainActor @Sendable (String) -> Void)? = nil) {
        self.sink = sink
    }

    func announce(_ event: RunAnnouncement) {
        let text = event.localizedText
        if let sink {
            sink(text)
            return
        }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier)
        synthesizer.speak(utterance)
    }
}

@MainActor
struct SilentAnnouncer: Announcing {
    func announce(_ event: RunAnnouncement) {}
}
