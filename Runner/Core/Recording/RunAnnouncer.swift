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

/// Internal seam over `AVAudioSession` so the ducking lifecycle can be
/// unit-tested without ever touching real audio hardware. Not part of the
/// public `Announcing` surface.
protocol AudioSessionControlling: Sendable {
    func activate()
    func deactivate()
}

struct SystemAudioSession: AudioSessionControlling {
    func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

/// Tracks how many spoken utterances are currently in flight and drives the
/// audio session accordingly: activate (duck) as soon as one is queued,
/// deactivate (un-duck) only once every queued utterance has finished or
/// been cancelled. This prevents the activate/deactivate flap that would
/// happen if two cues land back to back, and — critically — prevents the
/// session from staying active (and other apps ducked) for the rest of the
/// run once speech has actually finished.
@MainActor
final class SpeechSessionTracker {
    private let audioSession: AudioSessionControlling
    private var pendingUtterances = 0

    init(audioSession: AudioSessionControlling) {
        self.audioSession = audioSession
    }

    func utteranceQueued() {
        pendingUtterances += 1
        audioSession.activate()
    }

    func utteranceEnded() {
        pendingUtterances = max(0, pendingUtterances - 1)
        if pendingUtterances == 0 {
            audioSession.deactivate()
        }
    }
}

@MainActor
final class RunAnnouncer: NSObject, Announcing {
    private let synthesizer = AVSpeechSynthesizer()
    private let sink: (@MainActor @Sendable (String) -> Void)?
    private let sessionTracker: SpeechSessionTracker

    init(sink: (@MainActor @Sendable (String) -> Void)? = nil, audioSession: AudioSessionControlling = SystemAudioSession()) {
        self.sink = sink
        self.sessionTracker = SpeechSessionTracker(audioSession: audioSession)
        super.init()
        synthesizer.delegate = self
    }

    func announce(_ event: RunAnnouncement) {
        let text = event.localizedText
        if let sink {
            sink(text)
            return
        }

        sessionTracker.utteranceQueued()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier)
        synthesizer.speak(utterance)
    }
}

extension RunAnnouncer: AVSpeechSynthesizerDelegate {
    // AVSpeechSynthesizerDelegate callbacks are not guaranteed to arrive on
    // the main actor, so these witnesses stay nonisolated and hop onto the
    // main actor themselves before touching any MainActor-isolated state
    // (sessionTracker). This keeps AVSpeechSynthesizer — which is not
    // Sendable — from ever crossing an actor boundary: only the completion
    // signal crosses, not the synthesizer or utterance.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.sessionTracker.utteranceEnded()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.sessionTracker.utteranceEnded()
        }
    }
}

@MainActor
struct SilentAnnouncer: Announcing {
    func announce(_ event: RunAnnouncement) {}
}
