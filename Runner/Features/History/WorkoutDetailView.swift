import SwiftUI

struct WorkoutDetailView: View {
    let workout: WorkoutRec

    private var route: [RoutePoint] {
        workout.routeData.map { [RoutePoint].decode($0) } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if route.count >= 2 {
                    RouteMapView(points: route, interactive: true)
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.rBorder, lineWidth: 1))
                } else {
                    SurfaceCard {
                        Label(String(localized: "No route for this workout (imported from Health)"),
                              systemImage: "map")
                            .font(.caption)
                            .foregroundStyle(Color.rTextSecondary)
                    }
                }

                HStack(spacing: 10) {
                    StatTile(label: String(localized: "Points"), value: "+\(workout.points)", accent: .rLime)
                    StatTile(label: String(localized: "Distance"), value: Format.km(workout.distanceMeters))
                    StatTile(label: String(localized: "Time"),
                             value: workout.movingSeconds > 0 ? Format.duration(workout.movingSeconds) : "—")
                }

                if !workout.splitSeconds.isEmpty {
                    SplitsCard(splitSeconds: workout.splitSeconds,
                               title: String(localized: "Splits"))
                }
                Spacer(minLength: 90)
            }
            .padding(18)
        }
        .background(Color.rBackground)
        .navigationTitle("\(workout.type.emoji) \(workout.start.formatted(date: .abbreviated, time: .shortened))")
        .navigationBarTitleDisplayMode(.inline)
    }
}
