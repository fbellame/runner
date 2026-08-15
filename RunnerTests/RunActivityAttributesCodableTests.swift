import Testing
import Foundation
@testable import Runner

/// `RunAttributes` and its `ContentState` have hand-written `Codable`
/// conformances (`RunActivityAttributes.swift`) because the compiler can't
/// synthesize `Codable` from an extension in a different file than the type
/// declaration. Until now that hand-written code was verified by inspection
/// only. In Task 9 a decode mismatch here means the widget extension
/// receives garbage — it decodes the exact bytes ActivityKit round-trips
/// across the process boundary, using only the types themselves, the same
/// way the OS does.
@Suite struct RunActivityAttributesCodableTests {
    @Test func runAttributesRoundTripsThroughJSON() throws {
        let original = RunAttributes(sessionID: UUID())

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RunAttributes.self, from: data)

        #expect(decoded.sessionID == original.sessionID)
    }

    @Test func contentStateRoundTripsThroughJSON() throws {
        let original = RunAttributes.ContentState(snapshot: RunActivitySnapshot(
            status: .recording,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            movingSeconds: 312.5,
            distanceMeters: 1834.2,
            paceSecondsPerKm: 271.9,
            reducedAccuracy: true,
            message: "Precise Location is off"
        ))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RunAttributes.ContentState.self, from: data)

        #expect(decoded == original)
    }

    /// `paceSecondsPerKm`/`message` are `nil` for most of a run's life (no
    /// pace under 100 m, no message unless location is degraded) — cover
    /// that shape too, since `Optional`-with-`nil` is a distinct encoding
    /// path from a populated value.
    @Test func contentStateRoundTripsWithNilOptionals() throws {
        let original = RunAttributes.ContentState(snapshot: RunActivitySnapshot(
            status: .ready,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            movingSeconds: 0,
            distanceMeters: 0,
            paceSecondsPerKm: nil,
            reducedAccuracy: false,
            message: nil
        ))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RunAttributes.ContentState.self, from: data)

        #expect(decoded == original)
    }
}
