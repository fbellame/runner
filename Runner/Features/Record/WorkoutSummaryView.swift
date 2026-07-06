import SwiftUI

struct WorkoutSummaryView: View {
    let workout: RecordedWorkout
    let onSave: () -> Void
    let onDiscard: () -> Void

    private var points: Int {
        PointsEngine.workoutPoints(type: workout.type, distanceMeters: workout.distanceMeters)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("\(workout.type.emoji) \(workout.type.localizedName)")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 18)

            RouteMapView(points: workout.route, interactive: true)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.rBorder, lineWidth: 1))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("+\(points)")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.rLime)
                    .modifier(GlowShadow(color: .rLime))
                Text("PTS")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.rLime)
            }

            HStack(spacing: 10) {
                stat(String(localized: "Distance"), Format.km(workout.distanceMeters))
                stat(String(localized: "Time"), Format.duration(workout.movingSeconds))
                stat(String(localized: "Pace"),
                     Format.pace(workout.distanceMeters >= 100
                                 ? workout.movingSeconds / (workout.distanceMeters / 1000)
                                 : nil))
            }

            if !workout.splitSeconds.isEmpty {
                SurfaceCard {
                    VStack(spacing: 6) {
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

            Spacer()

            VStack(spacing: 10) {
                Button(action: onSave) {
                    Text(String(localized: "Save workout"))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rBackground)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Capsule().fill(Color.rLime))
                }
                Button(action: onDiscard) {
                    Text(String(localized: "Discard"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.rTextSecondary)
                }
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 18)
        .background(Color.rBackground)
        .interactiveDismissDisabled()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 4) {
                MicroLabel(text: label)
                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}
