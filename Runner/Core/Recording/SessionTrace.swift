import CoreLocation
import Foundation

/// Writes what the recorder actually saw and actually decided, one line per GPS
/// sample, to a CSV in the app's Documents directory.
///
/// The auto-pause tuning has been done twice from memories of a run ("it paused
/// too late", "it started on its own"). Both rounds were guesswork about a
/// signal nobody had ever looked at: my own tests use a GPS noise model I
/// invented. A trace turns the next field test into data — the same file can be
/// replayed through the recorder in a unit test, so a real failure becomes a
/// permanent regression test instead of an anecdote.
///
/// Deliberately dumb: append-only text, no buffering policy beyond the file
/// handle's own, no schema versioning. It is a diagnostic, not a data format.
@MainActor
final class SessionTrace {
    /// One column per thing that could plausibly explain a wrong decision.
    static let header = "t,lat,lon,acc,sensorSpeed,usedSpeed,state,armed,motion,event\n"
    /// Traces are kept for the last few sessions only; they are worth a few
    /// hundred KB each and nobody wants a year of them on the phone.
    static let keepNewest = 8

    private let fileURL: URL
    private var handle: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Nil when tracing could not be set up at all — the caller carries on
    /// recording the run, which matters infinitely more than the diagnostic.
    init?(directory: URL? = SessionTrace.defaultDirectory, startedAt: Date, activity: String) {
        guard let directory else { return nil }
        let stamp = ISO8601DateFormatter().string(from: startedAt)
            .replacingOccurrences(of: ":", with: "-")
        fileURL = directory.appendingPathComponent("\(stamp)-\(activity).csv")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.excludeFromBackup(directory)
            try Self.header.write(to: fileURL, atomically: true, encoding: .utf8)
            handle = try FileHandle(forWritingTo: fileURL)
            try handle?.seekToEnd()
        } catch {
            return nil
        }
        Self.prune(in: directory)
    }

    static var defaultDirectory: URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// Keeps traces out of iCloud and iTunes backups.
    ///
    /// A trace is a CSV of raw lat/lon — the first row of a run trace is the
    /// front door. `UIFileSharingEnabled` already exposes this folder in the
    /// Files app on purpose, which is the point of the diagnostic; silently
    /// copying it into every backup is not, and the data is disposable by
    /// construction (only the newest `keepNewest` survive anyway). Best-effort:
    /// a failure here must never stop a run from being traced.
    static func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// `event` carries the state transitions — the rows worth grepping for.
    func record(location: CLLocation, usedSpeed: Double?, state: String,
                armed: Bool, motion: String, event: String = "") {
        let row = [
            formatter.string(from: location.timestamp),
            String(format: "%.6f", location.coordinate.latitude),
            String(format: "%.6f", location.coordinate.longitude),
            String(format: "%.1f", location.horizontalAccuracy),
            String(format: "%.2f", location.speed),
            usedSpeed.map { String(format: "%.2f", $0) } ?? "",
            state, armed ? "1" : "0", motion, event
        ].joined(separator: ",")
        write(row + "\n")
    }

    /// A state change that did not come from a GPS sample. `ingest` returns early
    /// while `.manuallyPaused`, so without this the trace just stops for the length
    /// of a manual pause — indistinguishable, on the way back in, from a dead
    /// signal. One real 29-minute manual pause read exactly like a lost fix.
    func mark(event: String, state: String, at time: Date) {
        let row = [formatter.string(from: time), "", "", "", "", "",
                   state, "", "", event].joined(separator: ",")
        write(row + "\n")
    }

    private func write(_ text: String) {
        guard let handle, let data = text.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    private static func prune(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        // Names are ISO timestamps, so lexicographic order IS chronological
        // order — no need to stat every file for a creation date.
        let sorted = files.filter { $0.pathExtension == "csv" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in sorted.dropFirst(keepNewest) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
