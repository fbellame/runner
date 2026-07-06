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
                    detailStat(String(localized: "Points"), "+\(workout.points)", accent: .rLime)
                    detailStat(String(localized: "Distance"), Format.km(workout.distanceMeters), accent: .white)
                    detailStat(String(localized: "Time"),
                               workout.movingSeconds > 0 ? Format.duration(workout.movingSeconds) : "—",
                               accent: .white)
                }

                if !workout.splitSeconds.isEmpty {
                    SurfaceCard {
                        VStack(spacing: 6) {
                            MicroLabel(text: String(localized: "Splits"))
                            ForEach(Array(workout.splitSeconds.enumerated()), id: \.offset) { index, seconds in
                                HStack {
                                    Text(String(localized: "Km \(index + 1)"))
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.rTextSecondary)
                                    Spacer()
                                    Text(Format.duration(seconds))
                                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 90)
            }
            .padding(18)
        }
        .background(Color.rBackground)
        .navigationTitle("\(workout.type.emoji) \(workout.start.formatted(date: .abbreviated, time: .shortened))")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailStat(_ label: String, _ value: String, accent: Color) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 4) {
                MicroLabel(text: label)
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}
