import SwiftUI
import MapKit

struct RouteMapView: View {
    let points: [RoutePoint]
    var interactive: Bool = false

    private struct Segment: Identifiable {
        let id: Int
        let coords: [CLLocationCoordinate2D]
        let isGapConnector: Bool
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        var current: [CLLocationCoordinate2D] = []
        var id = 0

        for point in points {
            let coord = point.coordinate
            if point.afterGap, let last = current.last {
                out.append(Segment(id: id, coords: current, isGapConnector: false))
                id += 1
                out.append(Segment(id: id, coords: [last, coord], isGapConnector: true))
                id += 1
                current = [coord]
            } else {
                current.append(coord)
            }
        }

        if current.count >= 2 {
            out.append(Segment(id: id, coords: current, isGapConnector: false))
        }
        return out
    }

    static func fittingRegion(for points: [RoutePoint],
                              paddingFactor: Double = 1.4,
                              minSpan: Double = 0.004) -> MKCoordinateRegion {
        guard let first = points.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 45.5,
                                                                     longitude: -73.6),
                                      span: MKCoordinateSpan(latitudeDelta: 0.02,
                                                             longitudeDelta: 0.02))
        }

        var minLat = first.lat
        var maxLat = first.lat
        var minLon = first.lon
        var maxLon = first.lon
        for point in points {
            minLat = min(minLat, point.lat)
            maxLat = max(maxLat, point.lat)
            minLon = min(minLon, point.lon)
            maxLon = max(maxLon, point.lon)
        }

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * paddingFactor, minSpan),
                                   longitudeDelta: max((maxLon - minLon) * paddingFactor, minSpan))
        )
    }

    private var region: MKCoordinateRegion {
        Self.fittingRegion(for: points)
    }

    var body: some View {
        Map(initialPosition: .region(region), interactionModes: interactive ? .all : []) {
            ForEach(segments) { segment in
                if segment.isGapConnector {
                    MapPolyline(coordinates: segment.coords)
                        .stroke(Color.rLime.opacity(0.4),
                                style: StrokeStyle(lineWidth: 2.5, dash: [5, 7]))
                } else {
                    MapPolyline(coordinates: segment.coords)
                        .stroke(Color.rLime.opacity(0.25), lineWidth: 9)
                    MapPolyline(coordinates: segment.coords)
                        .stroke(Color.rLime,
                                style: StrokeStyle(lineWidth: 3.5,
                                                   lineCap: .round,
                                                   lineJoin: .round))
                }
            }
            if let first = points.first {
                Annotation("", coordinate: first.coordinate) {
                    Circle()
                        .stroke(Color.rLime, lineWidth: 3)
                        .background(Circle().fill(Color.rBackground))
                        .frame(width: 12, height: 12)
                }
            }
            if points.count > 1, let last = points.last {
                Annotation("", coordinate: last.coordinate) {
                    Circle()
                        .fill(Color.rLime)
                        .frame(width: 11, height: 11)
                        .modifier(GlowShadow(color: .rLime))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }
}
