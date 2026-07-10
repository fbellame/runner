import SwiftUI

struct WorkoutSummaryView: View {
    let workout: RecordedWorkout
    var achievements: [Achievement] = []
    var isSaving = false
    let onSave: () -> Void
    let onDiscard: () -> Void

    private var points: Int {
        PointsEngine.workoutPoints(type: workout.type, distanceMeters: workout.distanceMeters)
    }

    var body: some View {
        VStack(spacing: 16) {
            if !achievements.isEmpty {
                achievementBanner
            }

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

    private var achievementBanner: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Color.rLime.opacity(0.2), Color.rTeal.opacity(0.12)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.rLime.opacity(0.7), lineWidth: 1))
            CelebrationBurst()
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "New achievements"))
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(Color.rLime)
                ForEach(achievements) { achievement in
                    achievementRow(achievement)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(minHeight: 76)
    }

    @ViewBuilder
    private func achievementRow(_ achievement: Achievement) -> some View {
        switch achievement.kind {
        case .newRecord(let record):
            HStack {
                Text(String(format: String(localized: "%@ %@!"),
                            RecordRow.emoji(record.kind), RecordRow.title(record.kind)))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text(RecordRow.value(record))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.rTeal)
            }
        case .newBadge(let badge):
            HStack {
                Text("🎖️ \(badgeAchievementTitle(badge))")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
            }
        }
    }

    private func badgeAchievementTitle(_ badge: Badge) -> String {
        let amount: String
        switch badge.kind {
        case .distance: amount = String(format: String(localized: "%lld km"), Int64(badge.threshold))
        case .count: amount = String(format: String(localized: "%lld workouts"), Int64(badge.threshold))
        }
        return String(format: String(localized: "%@ lifetime %@"), amount, badgeScopeName(badge.scope))
    }

    private func badgeScopeName(_ scope: BadgeScope) -> String {
        switch scope {
        case .global: String(localized: "all activities")
        case .perType(let type): type.localizedName
        }
    }
}
