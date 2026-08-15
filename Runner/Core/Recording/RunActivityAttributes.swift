import Foundation
import ActivityKit

// `RunAttributes`'s `ActivityAttributes` conformance, `ContentState`, and
// hand-written `Codable` conformance live in their OWN file — separate from
// `LiveActivityController.swift` — so Task 9's widget extension target can
// include just this file (plus Task 7's ActivityKit-free `RunAttributes.swift`)
// without also pulling in the `@MainActor` controller, which the widget has
// no use for. Do NOT move these back into `RunAttributes.swift` itself —
// that file is deliberately ActivityKit-free so the test target never has to
// `import ActivityKit`. Do NOT re-declare `ContentState` in the widget
// target either: it must be exactly this type, or decoding silently breaks.
extension RunAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        let snapshot: RunActivitySnapshot
    }
}

// `Codable` can only be synthesized by the compiler from an extension that
// lives in the same file as the type it extends — `RunAttributes` itself is
// declared in `RunAttributes.swift`, so that synthesis doesn't reach here.
// Implemented by hand instead of moving/duplicating the type.
extension RunAttributes: Codable {
    private enum CodingKeys: String, CodingKey { case sessionID }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sessionID: try container.decode(UUID.self, forKey: .sessionID))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
    }
}
