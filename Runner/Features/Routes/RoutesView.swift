import SwiftUI
import SwiftData
import MapKit

struct RoutesView: View {
    @Query(sort: \WorkoutRec.start, order: .reverse) private var workouts: [WorkoutRec]
    @State private var filter: ActivityType?
    @State private var selected: WorkoutRec?
    // Decoded once when the workout set or filter changes, not on every body pass.
    @State private var routed: [(rec: WorkoutRec, points: [RoutePoint])] = []

    private func rebuild() {
        routed = workouts.compactMap { rec in
            guard filter == nil || rec.type == filter,
                  let data = rec.routeData else { return nil }
            let points = [RoutePoint].decode(data)
            return points.count >= 2 ? (rec, points) : nil
        }
    }

    private var region: MKCoordinateRegion {
        RouteMapView.fittingRegion(for: routed.flatMap(\.points),
                                   paddingFactor: 1.3,
                                   minSpan: 0.01)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                MapReader { proxy in
                    Map(initialPosition: .region(region)) {
                        ForEach(routed, id: \.rec.id) { item in
                            MapPolyline(coordinates: item.points.map {
                                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                            })
                            .stroke(item.rec.type.accent.opacity(0.9),
                                    style: StrokeStyle(lineWidth: 3,
                                                       lineCap: .round,
                                                       lineJoin: .round))
                        }
                    }
                    .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                    .onTapGesture { screenPoint in
                        guard let coord = proxy.convert(screenPoint, from: .local) else { return }
                        let hit = RouteHitTest.nearestWorkout(
                            toLat: coord.latitude,
                            lon: coord.longitude,
                            routes: routed.map { ($0.rec.id, $0.points) },
                            maxMeters: 120
                        )
                        selected = routed.first { $0.rec.id == hit }?.rec
                    }
                }
                .ignoresSafeArea(edges: .top)

                filterChips
            }
            .background(Color.rBackground)
            .onAppear(perform: rebuild)
            .onChange(of: workouts.map(\.id)) { _, _ in rebuild() }
            .onChange(of: filter) { _, _ in rebuild() }
            .navigationDestination(item: $selected) { workout in
                WorkoutDetailView(workout: workout)
            }
            .overlay(alignment: .bottom) {
                if routed.isEmpty {
                    SurfaceCard {
                        Text(String(localized: "No routes yet — record a run, walk or ride and your city starts glowing."))
                            .font(.subheadline)
                            .foregroundStyle(Color.rTextSecondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 100)
                }
            }
        }
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            chip(nil, label: String(localized: "All"))
            ForEach(ActivityType.allCases, id: \.self) { type in
                chip(type, label: "\(type.emoji) \(type.localizedName)")
            }
        }
        .padding(.top, 8)
    }

    private func chip(_ type: ActivityType?, label: String) -> some View {
        Button {
            filter = type
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(filter == type
                                           ? Color.rLime
                                           : Color.rSurface.opacity(0.9)))
                .overlay(Capsule().stroke(Color.rBorder,
                                           lineWidth: filter == type ? 0 : 1))
                .foregroundStyle(filter == type ? Color.rBackground : .white)
        }
        .buttonStyle(.plain)
    }
}
