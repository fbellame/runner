import SwiftUI
import SwiftData
import MapKit

struct RoutesView: View {
    @Query(sort: \WorkoutRec.start, order: .reverse) private var workouts: [WorkoutRec]
    @State private var filter: ActivityType?
    @State private var selected: WorkoutRec?
    // Decoded once when the workout set or filter changes, not on every body pass.
    @State private var routed: [(rec: WorkoutRec, points: [RoutePoint])] = []
    /// Decoded routes, kept across rebuilds and keyed by workout id.
    ///
    /// `rebuild()` runs on appear, on every change to the workout set, and on
    /// every filter tap — and it used to JSON-decode every matching route blob
    /// from scratch each time, synchronously on the main actor. Route blobs are
    /// the largest thing in the store; tapping "All" after "Run" re-decoded the
    /// runs it had just decoded. A route is written once with its workout and
    /// never edited, so a decode is good forever.
    @State private var decoded: [UUID: [RoutePoint]] = [:]
    /// The camera, held in state.
    ///
    /// This screen passed `Map(initialPosition: .region(region))`, with `region`
    /// derived from `routed` — which is empty at first render, because it is
    /// filled in `.onAppear`. `initialPosition` is honoured once and ignored on
    /// every update, so the camera was always set from the empty case and fell
    /// through to `fittingRegion`'s literal fallback. The map never framed the
    /// routes at all; it was invisible only because that fallback is Montreal.
    @State private var camera: MapCameraPosition = .region(RouteMapView.fittingRegion(for: []))

    /// Thin wrapper over `RouteSelection.visible`: the filtering, decoding,
    /// caching and two-point rule are pure and tested there, and only the
    /// mapping back onto `WorkoutRec` (for `navigationDestination`) and the
    /// camera assignment need to happen here.
    private func rebuild() {
        let byID = Dictionary(uniqueKeysWithValues: workouts.map { ($0.id, $0) })
        let result = RouteSelection.visible(
            workouts.map { (id: $0.id, type: $0.type, routeData: $0.routeData) },
            filter: filter,
            cache: decoded)

        routed = result.items.compactMap { item in
            byID[item.id].map { (rec: $0, points: item.points) }
        }
        decoded = result.cache
        camera = .region(RouteMapView.fittingRegion(for: result.allPoints,
                                                    paddingFactor: 1.3,
                                                    minSpan: 0.01))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                MapReader { proxy in
                    Map(position: $camera) {
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
