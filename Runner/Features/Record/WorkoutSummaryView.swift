import SwiftUI

struct WorkoutSummaryView: View {
    let workout: RecordedWorkout
    var isSaving = false
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

            GlowNumber(value: points, unitLabel: "PTS",
                       prefix: "+", size: 44, unitSize: 14, numberColor: .rLime)

            HStack(spacing: 10) {
                StatTile(label: String(localized: "Distance"), value: Format.km(workout.distanceMeters))
                StatTile(label: String(localized: "Time"), value: Format.duration(workout.movingSeconds))
                StatTile(label: String(localized: "Pace"), value: Format.pace(workout.paceSecondsPerKm))
            }

            if !workout.splitSeconds.isEmpty {
                SplitsCard(splitSeconds: workout.splitSeconds)
            }

            Spacer()

            VStack(spacing: 10) {
                Button(action: onSave) {
                    Group {
                        if isSaving {
                            ProgressView().tint(Color.rBackground)
                        } else {
                            Text(String(localized: "Save workout"))
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                        }
                    }
                    .foregroundStyle(Color.rBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Capsule().fill(Color.rLime))
                }
                .disabled(isSaving)
                Button(action: onDiscard) {
                    Text(String(localized: "Discard"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.rTextSecondary)
                }
                .disabled(isSaving)
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 18)
        .background(Color.rBackground)
        .interactiveDismissDisabled()
    }
}
