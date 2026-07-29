import Foundation
import AVFoundation

enum RunAnnouncement: Equatable, Sendable {
    case runStarted
    case paused
    case resumed
    case runSaved
    case runCancelled
    case locationDenied
    case kmSplit(km: Int, splitSeconds: Double)

    var localizedText: String {
        switch self {
        case .runStarted: String(localized: "Run started")
        case .paused: String(localized: "Paused")
        case .resumed: String(localized: "Resumed")
        case .runSaved: String(localized: "Run saved")
        case .runCancelled: String(localized: "Run cancelled")
        case .locationDenied: String(localized: "Location access is required")
        case .kmSplit(let km, let splitSeconds): Self.kmSplitText(km: km, splitSeconds: splitSeconds)
        }
    }

    /// Kept out of `localizedText`'s switch on purpose: that switch is a
    /// switch *expression* (implicit return per case), so a case body with
    /// statements — the early exit for a missing split, in particular — will
    /// not compile inline.
    private static func kmSplitText(km: Int, splitSeconds: Double) -> String {
        let distance = km == 1
            ? String(localized: "1 kilometer")
            : String(localized: "\(km) kilometers")
        let total = max(0, Int(splitSeconds.rounded()))
        guard total > 0 else { return "\(distance)." }
        let minutes = total / 60
        let seconds = total % 60
        // Two pace variants rather than one padded format: a speech
        // synthesiser reads "5 minutes 0" aloud on an exact minute, and "05"
        // as "zero five".
        let pace = seconds == 0
            ? String(localized: "Pace \(minutes) minutes per kilometer")
            : String(localized: "Pace \(minutes) minutes \(seconds) per kilometer")
        return "\(distance). \(pace)."
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
    // The category/mode/options never change for the lifetime of the app, but
    // `setCategory` forces a full audio-route re-evaluation. Previously this
    // ran synchronously on every `activate()` call — i.e. on every GPS sample
    // that triggered a cue, on the @MainActor — and could hitch the HUD by
    // ~100 ms bringing a Bluetooth route up from idle. Setting it once here,
    // at construction (this type is instantiated exactly once per app run —
    // see `RunAnnouncer.init`), means `activate()` only ever does the
    // unavoidable per-utterance `setActive`.
    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    func activate() {
        let session = AVAudioSession.sharedInstance()
        // Re-set the category only if something else took it. A mediaserverd
        // reset silently reverts the session to `.soloAmbient`, and setting the
        // category once at init would leave every later cue mute and un-ducking
        // for the rest of the app run. Reading `category` is a cached property
        // read, not the route re-evaluation that `setCategory` forces, so this
        // keeps the per-cue path cheap while staying self-healing.
        if session.category != .playback {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
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
