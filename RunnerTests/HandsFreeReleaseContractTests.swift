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
        #expect(String(localized: "Last kilometer \(5) minutes \(38)", locale: fr)
                == "Dernier kilomètre : 5 minutes 38")
        #expect(String(localized: "Last kilometer \(5) minutes", locale: fr)
                == "Dernier kilomètre : 5 minutes")
        #expect(String(localized: "Average \(5) minutes \(50) per kilometer", locale: fr)
                == "Moyenne : 5 minutes 50 par kilomètre")
        #expect(String(localized: "Average \(6) minutes per kilometer", locale: fr)
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
