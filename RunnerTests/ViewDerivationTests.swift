import Testing
import Foundation
import MapKit
@testable import Runner

/// The four defects the 2026-09-05 audit fixed by hand, now pinned.
///
/// Each was a pure function living inside a `View` body, in files at 0.00%
/// coverage — so 413 green tests said nothing about any of them. Nothing here
/// needed a UI test; it needed the derivation to be somewhere a test could call
/// it. (The fourth, clamp-then-persist, was already outside the view layer in
/// `AppModel` and is pinned by `AuditFixTests`.)

/// `@MainActor` because `RouteMapView.fittingRegion` is a static on a SwiftUI
/// `View` and so inherits its isolation — the framing assertions call it.
@MainActor
struct RouteSelectionTests {

    /// Fixed timestamps, not `Date()`. `RoutePoint` is `Equatable` over `t`, so
    /// a computed fixture mints fresh dates on every access and a round-tripped
    /// point can never compare equal to a freshly built one.
    private static func point(_ lat: Double, _ lon: Double, _ offset: TimeInterval) -> RoutePoint {
        RoutePoint(lat: lat, lon: lon,
                   t: Date(timeIntervalSince1970: 1_780_000_000 + offset), afterGap: false)
    }

    private func blob(_ points: [RoutePoint]) -> Data {
        (try? points.encoded()) ?? Data()
    }

    private func workout(_ type: ActivityType, _ points: [RoutePoint],
                         id: UUID = UUID()) -> (id: UUID, type: ActivityType, routeData: Data?) {
        (id: id, type: type, routeData: blob(points))
    }

    private let montreal = [point(45.50, -73.57, 0), point(45.52, -73.55, 60)]
    private let toronto = [point(43.65, -79.38, 0), point(43.67, -79.36, 60)]

    @Test func filterKeepsOnlyTheChosenActivity() {
        let workouts = [workout(.run, montreal), workout(.bike, toronto)]

        #expect(RouteSelection.visible(workouts, filter: nil).items.count == 2)
        #expect(RouteSelection.visible(workouts, filter: .run).items.count == 1)
        #expect(RouteSelection.visible(workouts, filter: .run).items.first?.type == .run)
        #expect(RouteSelection.visible(workouts, filter: .walk).items.isEmpty)
    }

    /// A single point is not a line. Drawing it produces an invisible polyline
    /// that still drags the camera toward it.
    @Test func aWorkoutWithFewerThanTwoPointsIsNotDrawn() {
        let workouts = [
            workout(.run, [Self.point(45.50, -73.57, 0)]),
            (id: UUID(), type: ActivityType.run, routeData: nil),
            workout(.run, montreal)
        ]
        let result = RouteSelection.visible(workouts, filter: nil)
        #expect(result.items.count == 1)
        #expect(result.items.first?.points.count == 2)
    }

    /// The performance rule, made observable. A route is written once with its
    /// workout and never edited, so a decode is good for the life of the
    /// process — before the cache, every filter tap re-decoded the blobs it had
    /// just decoded, synchronously on the main actor, and route blobs are the
    /// largest thing in the store.
    @Test func decodedRoutesAreReusedAcrossFilterChanges() {
        let runID = UUID()
        let workouts = [workout(.run, montreal, id: runID), workout(.bike, toronto)]

        let all = RouteSelection.visible(workouts, filter: nil)
        #expect(all.cache.count == 2)

        // Narrowing to one chip carries both decodes forward, not just the
        // visible one — so widening back to "All" costs nothing.
        let runsOnly = RouteSelection.visible(workouts, filter: .run, cache: all.cache)
        #expect(runsOnly.items.count == 1)
        #expect(runsOnly.cache.count == 2)

        // A cached decode is used even when the blob would no longer parse,
        // which is the only way to prove from outside that no decode happened.
        let corrupted = [(id: runID, type: ActivityType.run, routeData: Data("not json".utf8))]
        let reused = RouteSelection.visible(corrupted, filter: nil, cache: all.cache)
        #expect(reused.items.first?.points == montreal)

        // …and without the cache, the same input yields nothing.
        #expect(RouteSelection.visible(corrupted, filter: nil).items.isEmpty)
    }

    /// The defect itself: the camera was derived from `routed`, which is empty
    /// until `.onAppear` fills it, and `Map(initialPosition:)` is honoured once.
    /// So the region always came from the empty case and fell through to
    /// `fittingRegion`'s literal fallback — invisible only because that fallback
    /// is Montreal. A Toronto-only route makes the bug show.
    @Test func theFramedRegionContainsEveryDrawnRoute() {
        let result = RouteSelection.visible([workout(.run, toronto)], filter: nil)
        let region = RouteMapView.fittingRegion(for: result.allPoints,
                                                paddingFactor: 1.3, minSpan: 0.01)

        #expect(result.allPoints.isEmpty == false)
        for point in result.allPoints {
            #expect(abs(point.lat - region.center.latitude) <= region.span.latitudeDelta / 2)
            #expect(abs(point.lon - region.center.longitude) <= region.span.longitudeDelta / 2)
        }
        // Specifically not the Montreal fallback.
        #expect(abs(region.center.latitude - 45.5) > 1)
    }

    @Test func anEmptySelectionStillProducesAUsableRegion() {
        let region = RouteMapView.fittingRegion(for: RouteSelection.visible([], filter: nil).allPoints)
        #expect(region.span.latitudeDelta > 0)
        #expect(region.span.longitudeDelta > 0)
    }
}

struct HubChartRangeTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }

    private func summary(daysAgo: Int, asOf: Date, meters: Double = 5_000)
        -> ActivityWorkoutSummary {
        ActivityWorkoutSummary(id: UUID(), type: .run,
                               date: calendar.date(byAdding: .day, value: -daysAgo, to: asOf)!,
                               distanceMeters: meters, movingSeconds: 1_800, points: 75,
                               calories: 0, splitSeconds: [], hasRoute: false)
    }

    /// The defect: "12 wk" asked `weeklySeries` for weekly buckets and then
    /// filtered them with a *daily* cutoff, so the chart drew one bar. Bucket
    /// size and window size have to agree, and that agreement is the entire
    /// content of `series(...)`.
    @Test func twelveWeeksDrawsTwelveWeeklyBuckets() {
        let asOf = Date(timeIntervalSince1970: 1_780_000_000)
        let summaries = (0..<80).map { summary(daysAgo: $0, asOf: asOf) }

        let points = HubChartRange.twelveWeeks.series(summaries, type: .run,
                                                      asOf: asOf, calendar: calendar)

        #expect(points.count == 12)
        #expect(HubChartRange.twelveWeeks.calendarUnit == .weekOfYear)
        // Buckets are exactly a week apart and strictly ordered.
        for (earlier, later) in zip(points, points.dropFirst()) {
            #expect(later.date > earlier.date)
            #expect(calendar.dateComponents([.day], from: earlier.date, to: later.date).day == 7)
        }
    }

    @Test func oneYearDrawsTwelveMonthlyBuckets() {
        let asOf = Date(timeIntervalSince1970: 1_780_000_000)
        let summaries = (0..<300).map { summary(daysAgo: $0, asOf: asOf) }

        let points = HubChartRange.year.series(summaries, type: .run,
                                               asOf: asOf, calendar: calendar)

        #expect(points.count == 12)
        #expect(HubChartRange.year.calendarUnit == .month)
        for point in points {
            #expect(calendar.component(.day, from: point.date) == 1)
        }
    }

    /// "All" must reach the oldest workout — the range whose window is derived
    /// from the data rather than fixed.
    @Test func allSpansBackToTheOldestWorkout() {
        let asOf = Date(timeIntervalSince1970: 1_780_000_000)
        let summaries = [summary(daysAgo: 0, asOf: asOf), summary(daysAgo: 400, asOf: asOf)]

        let points = HubChartRange.all.series(summaries, type: .run,
                                              asOf: asOf, calendar: calendar)
        let oldest = try? #require(points.first?.date)

        #expect(points.count >= 14)   // 400 days ≥ 14 calendar months
        #expect(oldest != nil)
        if let oldest {
            #expect(oldest <= calendar.date(byAdding: .day, value: -400, to: asOf)!)
        }
        // Every drawn kilometre is accounted for, in both buckets.
        #expect(points.filter { $0.distanceMeters > 0 }.count == 2)
    }

    @Test func anEmptyHistoryStillProducesTheRangesBuckets() {
        let asOf = Date(timeIntervalSince1970: 1_780_000_000)
        for range in HubChartRange.allCases {
            let points = range.series([], type: .run, asOf: asOf, calendar: calendar)
            #expect(points.allSatisfy { $0.distanceMeters == 0 })
            #expect(points.allSatisfy { $0.avgPaceSecPerKm == nil })
        }
    }
}

struct WrappedBannerStateTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }

    /// 2026-03-15, so February is the newest complete month.
    private var asOf: Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 15))!
    }

    private func februarySummaries() -> [ActivityWorkoutSummary] {
        (1...10).map { day in
            ActivityWorkoutSummary(
                id: UUID(), type: .run,
                date: calendar.date(from: DateComponents(year: 2026, month: 2, day: day))!,
                distanceMeters: 5_000, movingSeconds: 1_800, points: 75,
                calories: 0, splitSeconds: [], hasRoute: false)
        }
    }

    @Test func offersTheNewestCompleteMonth() {
        let month = WrappedBannerState.pendingMonth(februarySummaries(), asOf: asOf,
                                                    calendar: calendar,
                                                    dismissedThisSession: nil,
                                                    isSeen: { _ in false })
        #expect(month?.year == 2026)
        #expect(month?.month == 2)
    }

    /// The defect. `markSeen` is a `UserDefaults` write, and SwiftUI does not
    /// observe those — so the ✕ persisted the dismissal and left the banner on
    /// screen anyway, until the next launch. The in-memory half is what makes
    /// the tap visible.
    @Test func aDismissalTakesEffectWithinTheSameSession() {
        let summaries = februarySummaries()
        let month = try? #require(
            WrappedBannerState.pendingMonth(summaries, asOf: asOf, calendar: calendar,
                                            dismissedThisSession: nil, isSeen: { _ in false }))

        #expect(WrappedBannerState.pendingMonth(summaries, asOf: asOf, calendar: calendar,
                                                dismissedThisSession: month,
                                                isSeen: { _ in false }) == nil)
    }

    /// And the durable half, which is what survives the relaunch the in-memory
    /// flag does not. Both are required; neither is sufficient.
    @Test func aSeenMonthStaysDismissedAcrossSessions() {
        #expect(WrappedBannerState.pendingMonth(februarySummaries(), asOf: asOf,
                                                calendar: calendar,
                                                dismissedThisSession: nil,
                                                isSeen: { _ in true }) == nil)
    }

    @Test func noMonthIsOfferedWithoutHistory() {
        #expect(WrappedBannerState.pendingMonth([], asOf: asOf, calendar: calendar,
                                                dismissedThisSession: nil,
                                                isSeen: { _ in false }) == nil)
    }
}
