import Testing
import Foundation
import CoreLocation
@testable import Runner

/// Reads a `SessionTrace` CSV back into locations.
///
/// This is the point of the whole trace: a real run that misbehaves becomes a
/// file, the file becomes a test, and the bug can never come back unnoticed.
/// Timestamps are rebased onto the moment of replay so `LocationFilter`'s
/// 10 s freshness check does not throw away a trace recorded last Tuesday.
enum TraceReplay {
    static func locations(from csv: String, anchoredTo anchor: Date) -> [CLLocation] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let rows = csv.split(separator: "\n").dropFirst()  // header
        var offset: TimeInterval?
        return rows.compactMap { row in
            let f = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let t = formatter.date(from: f[0]),
                  let lat = Double(f[1]), let lon = Double(f[2]),
                  let acc = Double(f[3]), let speed = Double(f[4]) else { return nil }
            if offset == nil { offset = anchor.timeIntervalSince(t) }
            return CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                altitude: 0, horizontalAccuracy: acc, verticalAccuracy: 10,
                course: -1, speed: speed,
                timestamp: t.addingTimeInterval(offset ?? 0)
            )
        }
    }
}

@MainActor
struct SessionTraceTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-tests-\(UUID().uuidString)")
    }

    private func loc(x: Double, t: TimeInterval, speed: Double) -> CLLocation {
        let lat = 45.5
        let lon = -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180))
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                          altitude: 30, horizontalAccuracy: 5, verticalAccuracy: 10,
                          course: 90, speed: speed, timestamp: Date().addingTimeInterval(t))
    }

    @Test func writesAHeaderAndOneRowPerSample() throws {
        let dir = tempDir()
        let trace = try #require(SessionTrace(directory: dir, startedAt: Date(), activity: "run"))
        trace.record(location: loc(x: 0, t: 0, speed: 3), usedSpeed: 3,
                     state: "recording", armed: false, motion: "")
        trace.record(location: loc(x: 3, t: 1, speed: 0), usedSpeed: 0.1,
                     state: "autoPaused", armed: false, motion: "stationary", event: "paused")
        trace.close()

        let file = try #require(try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        let csv = try String(contentsOf: file, encoding: .utf8)

        #expect(csv.hasPrefix(SessionTrace.header))
        #expect(csv.split(separator: "\n").count == 3)
        // The transition rows are the ones worth grepping for.
        #expect(csv.contains("paused"))
        #expect(csv.contains("stationary"))
    }

    /// `ingest` returns early while `.manuallyPaused`, so a manual pause used to
    /// make the trace simply stop — indistinguishable, on the way back in, from a
    /// dead signal. One real 29-minute manual pause read exactly like a lost fix.
    /// The mark rows carry no coordinate, so `TraceReplay` drops them and a replay
    /// still sees only real samples.
    @Test func marksRecordAStateChangeThatNoSampleWouldShow() throws {
        let dir = tempDir()
        let trace = try #require(SessionTrace(directory: dir, startedAt: Date(), activity: "run"))
        trace.record(location: loc(x: 0, t: 0, speed: 3), usedSpeed: 3,
                     state: "recording", armed: false, motion: "moving")
        trace.mark(event: "manual-pause", state: "manuallyPaused", at: Date())
        trace.mark(event: "manual-resume", state: "recording", at: Date())
        trace.record(location: loc(x: 3, t: 1, speed: 3), usedSpeed: 3,
                     state: "recording", armed: false, motion: "moving")
        trace.close()

        let file = try #require(try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        let csv = try String(contentsOf: file, encoding: .utf8)

        #expect(csv.contains("manual-pause"))
        #expect(csv.contains("manual-resume"))
        #expect(csv.split(separator: "\n").count == 5)   // header + 2 samples + 2 marks
        #expect(TraceReplay.locations(from: csv, anchoredTo: Date()).count == 2)
    }

    /// Round-trip: what the recorder writes must be replayable back through the
    /// recorder and produce the same verdicts.
    @Test func aWrittenTraceReplaysThroughTheRecorder() throws {
        let dir = tempDir()
        let trace = try #require(SessionTrace(directory: dir, startedAt: Date(), activity: "run"))
        // Ten seconds running, then seven standing still.
        for i in 0...9 {
            trace.record(location: loc(x: Double(i) * 3, t: Double(i), speed: 3),
                         usedSpeed: 3, state: "recording", armed: false, motion: "")
        }
        for i in 10...16 {
            trace.record(location: loc(x: 27, t: Double(i), speed: 0),
                         usedSpeed: 0, state: "recording", armed: false, motion: "")
        }
        trace.close()

        let file = try #require(try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        let csv = try String(contentsOf: file, encoding: .utf8)
        let replayed = TraceReplay.locations(from: csv, anchoredTo: Date().addingTimeInterval(-2))
        #expect(replayed.count == 17)

        let recorder = WorkoutRecorder(provider: FakeLocationProvider(),
                                       checkpoints: CheckpointStore(directory: tempDir()))
        recorder.start(activity: .run)
        for location in replayed { recorder.didUpdate(locations: [location]) }

        // The stop in the trace is the stop the recorder finds.
        #expect(recorder.state == .autoPaused)
        #expect(recorder.distanceMeters > 20)
    }

    @Test func onlyTheNewestTracesAreKept() throws {
        let dir = tempDir()
        for i in 0..<(SessionTrace.keepNewest + 4) {
            let started = Date().addingTimeInterval(Double(i) * 60)
            _ = try #require(SessionTrace(directory: dir, startedAt: started, activity: "run"))
        }
        let remaining = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "csv" }
        #expect(remaining.count <= SessionTrace.keepNewest)
    }
}
