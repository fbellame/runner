import Testing
import Foundation
@testable import Runner

/// Release contract for the v1.10 hands-free epic (Task 14).
///
/// These are guard tests, not discovery tests: every assertion here was already
/// satisfied when the file was written, because Phases 1-4 kept the version and
/// the string catalog current as they went. Their value is catching a *future*
/// regression — a version field edited in only one of the two targets, or a
/// hands-free string deleted from the catalog — not proving something new today.
struct HandsFreeReleaseContractTests {

    @Test func runnerMarketingVersionIsOnePointTen() {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        #expect(version == "1.10")
    }

    /// The build number must be a positive integer that only ever moves forward.
    /// It was bumped twice during the device-spike cycle (13 -> 14 -> 15); this
    /// pins the floor so a stale plan step can't silently walk it backwards and
    /// make the build un-installable over what is already on the device.
    @Test func runnerBuildNumberHasNotRegressed() throws {
        let raw = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        let build = try #require(raw.flatMap(Int.init))
        #expect(build >= 15)
    }

    /// Every user-facing string introduced by the hands-free epic has a real
    /// French translation.
    ///
    /// NOTE ON STRENGTH: `String(localized:)` falls back to returning the key
    /// itself when a lookup misses, so a bare non-empty check would pass even if
    /// the catalog were emptied — the plan's original version of this test was
    /// vacuous for exactly that reason. Pinning `locale:` to French and asserting
    /// the concrete translation makes it fail if the entry is deleted, left
    /// untranslated, or has its French value edited. It is also independent of
    /// whatever language the simulator's test host happens to be running in.
    @Test func handsFreeStringsHaveFrenchTranslations() {
        let fr = Locale(identifier: "fr")
        #expect(String(localized: "Start Run", locale: fr)
                == "Démarrer la course")
        #expect(String(localized: "Arm a run without unlocking Runner.", locale: fr)
                == "Armez une course sans déverrouiller Runner.")
        #expect(String(localized: "Run in progress", locale: fr)
                == "Course en cours")
        #expect(String(localized: "Run finished", locale: fr)
                == "Course terminée")
        #expect(String(localized: "Ready — start moving", locale: fr)
                == "Prêt — commencez à bouger")
        #expect(String(localized: "1 kilometer", locale: fr)
                == "1 kilomètre")
        #expect(String(localized: "\(2) kilometers", locale: fr)
                == "2 kilomètres")
        #expect(String(localized: "Pace \(5) minutes per kilometer", locale: fr)
                == "Rythme : 5 minutes par kilomètre")
        #expect(String(localized: "Pace \(5) minutes \(42) per kilometer", locale: fr)
                == "Rythme : 5 minutes 42 par kilomètre")
    }
}
