import Testing
import Foundation
import CoreLocation
@testable import Runner

/// Release contract for the v1.10 hands-free epic (Task 14).
///
/// These are guard tests, not discovery tests: every assertion here was already
/// satisfied when the file was written, because Phases 1-4 kept the version and
/// the string catalog current as they went. Their value is catching a *future*
/// regression — a version field edited in only one of the two targets, or a
/// hands-free string deleted from the catalog — not proving something new today.
struct HandsFreeReleaseContractTests {

    /// The marketing version must be a well-formed `major.minor` that does not
    /// walk backwards.
    ///
    /// This used to assert `version == "1.10"` outright, so it failed the moment
    /// 1.11 shipped — a red suite that everyone knew to ignore, which is the
    /// failure mode that lets a real regression through. Its sibling below had
    /// the right shape all along: pin a floor, not a literal. XcodeGen generates
    /// both Info.plists from `project.yml`, so the contract worth guarding is
    /// "the version is real and only moves forward", not "the version is the one
    /// I happened to be on when I wrote this".
    @Test func runnerMarketingVersionHasNotRegressed() throws {
        let raw = try #require(Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String)
        let parts = raw.split(separator: ".").compactMap { Int($0) }
        #expect(parts.count >= 2, "expected major.minor, got \(raw)")
        let major = try #require(parts.first)
        let minor = try #require(parts.dropFirst().first)
        #expect(major > 1 || (major == 1 && minor >= 11))
    }

    /// The build number must be a positive integer that only ever moves forward.
    /// This pins the floor so a stale plan step can't silently walk it backwards
    /// and make the build un-installable over what is already on the device.
    @Test func runnerBuildNumberHasNotRegressed() throws {
        let raw = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        let build = try #require(raw.flatMap(Int.init))
        #expect(build >= 23)
    }

    /// Every user-facing string introduced by the hands-free epic has a real
    /// French translation.
    ///
    /// NOTE ON STRENGTH: `String(localized:)` falls back to returning the key
    /// itself when a lookup misses, so a bare non-empty check would pass even if
    /// the catalog were emptied — the plan's original version of this test was
    /// vacuous for exactly that reason. Asserting the concrete translation makes
    /// it fail if the entry is deleted, left untranslated, or has its French
    /// value edited.
    ///
    /// NOTE ON `bundle:`: `locale:` alone picks the *formatting* locale, not the
    /// table the lookup reads — that one follows the host process's preferred
    /// languages. This test therefore used to assert nothing at all on an
    /// English simulator (every lookup returned its own key, and it only ever
    /// passed because the simulators it ran on were French); CI on a stock
    /// en-US runner is what exposed it. Resolving `fr.lproj` by hand pins the
    /// table, so the assertions hold in any language.
    @Test func handsFreeStringsHaveFrenchTranslations() throws {
        let fr = Locale(identifier: "fr")
        let path = try #require(
            Bundle.main.path(forResource: "fr", ofType: "lproj"),
            "the app bundle ships no French localization"
        )
        let french = try #require(Bundle(path: path))
        #expect(String(localized: "Start Run", bundle: french, locale: fr)
                == "Démarrer la course")
        #expect(String(localized: "Arm a run without unlocking Runner.", bundle: french, locale: fr)
                == "Armez une course sans déverrouiller Runner.")
        #expect(String(localized: "Run in progress", bundle: french, locale: fr)
                == "Course en cours")
        #expect(String(localized: "Run finished", bundle: french, locale: fr)
                == "Course terminée")
        #expect(String(localized: "Ready — start moving", bundle: french, locale: fr)
                == "Prêt — commencez à bouger")
        #expect(String(localized: "1 kilometer", bundle: french, locale: fr)
                == "1 kilomètre")
        #expect(String(localized: "\(2) kilometers", bundle: french, locale: fr)
                == "2 kilomètres")
        #expect(String(localized: "Pace \(5) minutes per kilometer", bundle: french, locale: fr)
                == "Rythme : 5 minutes par kilomètre")
        #expect(String(localized: "Pace \(5) minutes \(42) per kilometer", bundle: french, locale: fr)
                == "Rythme : 5 minutes 42 par kilomètre")
        #expect(String(localized: "Last kilometer \(5) minutes \(38)", bundle: french, locale: fr)
                == "Dernier kilomètre : 5 minutes 38")
        #expect(String(localized: "Last kilometer \(5) minutes", bundle: french, locale: fr)
                == "Dernier kilomètre : 5 minutes")
        #expect(String(localized: "Average \(5) minutes \(50) per kilometer", bundle: french, locale: fr)
                == "Moyenne : 5 minutes 50 par kilomètre")
        #expect(String(localized: "Average \(6) minutes per kilometer", bundle: french, locale: fr)
                == "Moyenne : 6 minutes par kilomètre")
    }
}

@MainActor
struct LocationProviderContractTests {
    /// `AutoPauseDetector` can only advance on samples it is handed, and
    /// nothing else in the recorder runs on wall-clock time. A distance filter
    /// therefore means "stop moving ⇒ stop being told anything ⇒ never
    /// auto-pause", which is exactly what happened in the field.
    @Test func liveProviderKeepsDeliveringWhileStandingStill() {
        #expect(SystemLocationProvider().configuredDistanceFilter == kCLDistanceFilterNone)
    }
}
