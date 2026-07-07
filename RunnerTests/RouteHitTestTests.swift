import Testing
import Foundation
@testable import Runner

struct RouteHitTestTests {
    private func point(x: Double, y: Double) -> RoutePoint {
        RoutePoint(lat: 45.5 + y / 111_320.0,
                   lon: -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180)),
                   t: .now,
                   afterGap: false)
    }

    @Test func findsNearestRouteWithinThreshold() {
        let a = UUID()
        let b = UUID()
        let routes = [
            (id: a, points: [point(x: 0, y: 0), point(x: 100, y: 0)]),
            (id: b, points: [point(x: 0, y: 500), point(x: 100, y: 500)]),
        ]
        let tap = point(x: 50, y: 30)

        #expect(RouteHitTest.nearestWorkout(toLat: tap.lat,
                                            lon: tap.lon,
                                            routes: routes,
                                            maxMeters: 100) == a)
    }

    @Test func returnsNilWhenNothingClose() {
        let routes = [(id: UUID(), points: [point(x: 0, y: 0), point(x: 100, y: 0)])]
        let tap = point(x: 50, y: 900)

        #expect(RouteHitTest.nearestWorkout(toLat: tap.lat,
                                            lon: tap.lon,
                                            routes: routes,
                                            maxMeters: 100) == nil)
    }

    @Test func emptyRoutesReturnsNil() {
        #expect(RouteHitTest.nearestWorkout(toLat: 45.5,
                                            lon: -73.6,
                                            routes: [],
                                            maxMeters: 100) == nil)
    }
}
