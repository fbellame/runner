import Foundation
import CoreLocation

enum RouteHitTest {
    static func nearestWorkout(toLat lat: Double, lon: Double,
                               routes: [(id: UUID, points: [RoutePoint])],
                               maxMeters: Double) -> UUID? {
        let tap = CLLocation(latitude: lat, longitude: lon)
        var best: (id: UUID, distance: Double)?

        for route in routes {
            for point in route.points {
                let distance = tap.distance(from: CLLocation(latitude: point.lat,
                                                             longitude: point.lon))
                if distance <= maxMeters && distance < (best?.distance ?? .infinity) {
                    best = (route.id, distance)
                }
            }
        }

        return best?.id
    }
}
