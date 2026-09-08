import Testing
import Foundation
import CoreLocation
@testable import Runner

/// Enforcement for the invariants in SPEC.md §15 that had none.
///
/// Each of those fifteen rules was paid for with a real bug, but only one
/// (§15.1's distance filter) was pinned by a test. The rest lived as prose: a
/// future edit could undo any of them and the suite would stay green, which is
/// the same as not having written them down. An invariant with no enforcement
/// is a comment.
///
/// These are guard tests, not discovery tests — every assertion here passes
/// today. Their value is the failure they produce later.

@MainActor
struct LocationConfigurationInvariantTests {

    /// §15.1, the other two thirds of it.
    ///
    /// `LocationProviderContractTests` already pins `distanceFilter`, but the
    /// same starvation arrives by two other routes. `pausesLocationUpdates`
    /// hands CoreLocation the decision the recorder is supposed to make, and it
    /// does not resume on its own. `allowsBackgroundLocationUpdates` is what
    /// keeps the run alive with the screen off — the whole hands-free epic.
    @Test func theProviderNeverLetsCoreLocationStopDeliveringSamples() {
        let provider = SystemLocationProvider()

        #expect(provider.configuredDistanceFilter == kCLDistanceFilterNone)
        #expect(provider.configuredPausesAutomatically == false)

        // Set in `startUpdates()`, not `init`, because iOS requires an
        // in-foreground start — so the assertion has to bracket a real start.
        #expect(provider.configuredAllowsBackgroundUpdates == false)
        provider.startUpdates()
        #expect(provider.configuredAllowsBackgroundUpdates)
        provider.stopUpdates()
    }

    /// The precondition for the assertion above: iOS raises on
    /// `allowsBackgroundLocationUpdates = true` when the mode is absent, and
    /// `audio` is what lets `RunAnnouncer` speak a kilometre split with the
    /// phone in a pocket. XcodeGen writes both from `project.yml`, so a plist
    /// edit is not the way either one would go missing — a `project.yml` edit is.
    @Test func theBackgroundModesTheRecorderDependsOnArePresent() throws {
        let modes = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        )
        #expect(modes.contains("location"))
        #expect(modes.contains("audio"))
    }
}

/// §15.8 and §15.15, enforced against the catalog file itself.
///
/// Both rules are about `Localizable.xcstrings` as a *file*, so both have to be
/// checked as text — the compiled `.strings` in the test bundle has already
/// resolved away the duplicates and cannot show them. Reading through
/// `#filePath` is what makes that possible from a test target.
struct StringCatalogInvariantTests {

    private static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)          // RunnerTests/InvariantEnforcementTests.swift
            .deletingLastPathComponent()          // RunnerTests/
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Runner/Resources/Localizable.xcstrings")
    }

    private static func catalogText() throws -> String {
        try String(contentsOf: catalogURL, encoding: .utf8)
    }

    /// §15.8 — never JSON-round-trip the catalog.
    ///
    /// Doing it once produced five duplicate keys. `JSONSerialization` cannot
    /// see them (the last one wins on parse) and neither can Xcode's editor, so
    /// the only way to catch this is to count key lines textually. Every
    /// top-level entry sits at exactly four spaces of indentation.
    @Test func theStringCatalogHasNoDuplicateKeys() throws {
        let keys = try Self.catalogText()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> Substring? in
                guard line.hasPrefix("    \""), line.hasSuffix("\": {") else { return nil }
                return line.dropFirst(5).dropLast(4)
            }
        #expect(keys.isEmpty == false, "found no keys — the catalog's shape changed")

        var seen: Set<Substring> = []
        var duplicates: [Substring] = []
        for key in keys where seen.insert(key).inserted == false { duplicates.append(key) }
        #expect(duplicates.isEmpty, "duplicate keys: \(duplicates.joined(separator: ", "))")
    }

    /// §15.15 — `%lld` with `Int64`, never `%d` with `Int`.
    ///
    /// On a 64-bit device `%d` against an `Int` reads the wrong half of the
    /// word, so a localized count renders as garbage. The whole catalog was
    /// converted in the 2026-09-05 audit; this keeps a hand-added string from
    /// reintroducing it. `%@` and the positional `%1$lld` forms are untouched.
    @Test func theStringCatalogUsesLongLongFormatSpecifiers() throws {
        let offenders = try Self.catalogText()
            .split(separator: "\n")
            .enumerated()
            .filter { $0.element.contains("%d") }
            .map { "line \($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }

        #expect(offenders.isEmpty,
                "use %lld with Int64:\n\(offenders.joined(separator: "\n"))")
    }

    /// The same rule on the call sites, which is where the mismatch actually
    /// originates: a `%lld` catalog entry fed a plain `Int` is still wrong.
    ///
    /// Scoped to `String(localized:)` literals on purpose. A hard-coded format
    /// that never reaches the catalog is out of §15.15's scope and `%d` is
    /// right there — `Format.duration` builds "1:23:45" with
    /// `String(format: "%d:%02d:%02d", …)` and always should. The first version
    /// of this test flagged those two lines, which is the failure mode the rule
    /// itself warns about: a test everyone learns to ignore.
    @Test func everyLocalizedFormatStringUsesLongLongSpecifiers() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Runner")
        let files = FileManager.default
            .enumerator(at: sourceRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(files.isEmpty == false, "found no Swift sources to scan")

        var scanned = 0
        var offenders: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in text.split(separator: "\n").enumerated()
            where line.contains("String(localized:") {
                scanned += 1
                guard line.contains("%d") else { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1): "
                                 + line.trimmingCharacters(in: .whitespaces))
            }
        }
        #expect(scanned > 0, "found no String(localized:) call sites — the scan missed them")
        #expect(offenders.isEmpty,
                "use %lld with Int64:\n\(offenders.joined(separator: "\n"))")
    }
}
