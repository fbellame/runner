import Foundation

/// What the Routes map should draw, given the store's workouts and the active
/// filter chip.
///
/// This was `RoutesView.rebuild()`, computed inside the view. Every rule in it
/// has been wrong at least once: the camera was framed from the pre-`onAppear`
/// empty case and so always fell through to `fittingRegion`'s Montreal
/// fallback, and before the caching pass every filter tap re-decoded route
/// blobs it had just decoded. Neither could be caught by a test, because
/// neither was reachable from one.
enum RouteSelection {

    /// A workout with a route worth drawing. A single point is not a line, so
    /// anything under two points is dropped rather than rendered as an
    /// invisible polyline that still counts toward the framing.
    static let minimumPointsToDraw = 2

    struct Item: Equatable {
        let id: UUID
        let type: ActivityType
        let points: [RoutePoint]
    }

    struct Result: Equatable {
        let items: [Item]
        /// The decode cache, carried forward. A route is written once with its
        /// workout and never edited, so a decode is good for the life of the
        /// process — this is what makes tapping between filter chips free.
        let cache: [UUID: [RoutePoint]]

        /// Every point on screen, in draw order — what the camera must frame.
        var allPoints: [RoutePoint] { items.flatMap(\.points) }
    }

    /// - Parameter cache: decodes from previous calls. Pass the previous
    ///   `Result.cache` back in; passing `[:]` every time is correct but slow,
    ///   which is exactly the regression this signature exists to make visible.
    static func visible(_ workouts: [(id: UUID, type: ActivityType, routeData: Data?)],
                        filter: ActivityType?,
                        cache: [UUID: [RoutePoint]] = [:]) -> Result {
        var cache = cache
        var items: [Item] = []

        for workout in workouts {
            guard filter == nil || workout.type == filter else { continue }
            guard let data = workout.routeData else { continue }

            let points: [RoutePoint]
            if let cached = cache[workout.id] {
                points = cached
            } else {
                points = [RoutePoint].decode(data)
                cache[workout.id] = points
            }

            guard points.count >= minimumPointsToDraw else { continue }
            items.append(Item(id: workout.id, type: workout.type, points: points))
        }

        return Result(items: items, cache: cache)
    }
}
