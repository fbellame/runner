import SwiftUI

struct TrophyRoomView: View {
    let summaries: [ActivityWorkoutSummary]
    let goalWeeks: [CompletedWeek]
    private let seenStore = TrophySeenStore()

    /// Derived once per pass and handed down.
    ///
    /// These were computed properties, and a computed property is not a cache:
    /// `activityBadges` was read once in each of four `badgeSection` calls and
    /// again via `badges` in `onAppear`, so `TrophyMath.allBadges` — ~43k
    /// iterations over a 766-workout history — ran five times per render.
    var body: some View {
        let activityBadges = TrophyMath.allBadges(summaries)
        let weeklyBadges = TrophyMath.weeklyBadges(goalWeeks, calendar: .current)

        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                weeklyGoalsSection(weeklyBadges)
                badgeSection(activityBadges, title: String(localized: "Global"),
                             scope: .global, accent: .rLime)
                badgeSection(activityBadges, title: ActivityType.run.localizedName,
                             scope: .perType(.run), accent: ActivityType.run.accent)
                badgeSection(activityBadges, title: ActivityType.walk.localizedName,
                             scope: .perType(.walk), accent: ActivityType.walk.accent)
                badgeSection(activityBadges, title: ActivityType.bike.localizedName,
                             scope: .perType(.bike), accent: ActivityType.bike.accent)
            }
            .padding(18)
        }
        .background(Color.rBackground)
        .navigationTitle(String(localized: "Trophy Room"))
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            seenStore.markSeen((activityBadges + weeklyBadges).filter(\.earned).map(\.id))
        }
    }

    private func weeklyGoalsSection(_ weeklyBadges: [Badge]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: String(localized: "Weekly goals"))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(weeklyBadges) { badge in
                    TrophyBadgeCell(badge: badge,
                                    accent: .rLime,
                                    isUnseen: badge.earned && !seenStore.isSeen(badge.id))
                }
            }
        }
    }

    private func badgeSection(_ activityBadges: [Badge], title: String,
                              scope: BadgeScope, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: title)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(activityBadges.filter { $0.scope == scope }) { badge in
                    TrophyBadgeCell(badge: badge,
                                    accent: accent,
                                    isUnseen: badge.earned && !seenStore.isSeen(badge.id))
                }
            }
        }
    }
}

private struct TrophyBadgeCell: View {
    let badge: Badge
    let accent: Color
    let isUnseen: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                badgeIcon
                if isUnseen {
                    Circle()
                        .fill(Color.rOrange)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.rBackground, lineWidth: 1))
                        .offset(x: 2, y: -2)
                }
            }
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(badge.earned ? .white : Color.rTextSecondary)
                .lineLimit(1)
            if let earnedAt = badge.earnedAt {
                Text(String(format: String(localized: "Earned %@"),
                            earnedAt.formatted(date: .abbreviated, time: .omitted)))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.rTextSecondary)
                    .lineLimit(1)
            } else {
                Text(progressText)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.rTextSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 116)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.rSurface))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(badge.earned ? accent.opacity(0.7) : Color.rBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var badgeIcon: some View {
        if badge.earned {
            Text("🏆")
                .font(.system(size: 30))
                .frame(width: 48, height: 48)
                .background(Circle().fill(accent.opacity(0.16)))
        } else {
            ZStack {
                Circle().stroke(Color.rBorder, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: badge.progress)
                    .stroke(Color.rTextSecondary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("🔒")
                    .font(.system(size: 18))
            }
            .frame(width: 48, height: 48)
            .grayscale(1)
        }
    }

    private var title: String {
        switch badge.kind {
        case .distance: String(format: String(localized: "%lld km"), Int64(badge.threshold))
        case .count: String(format: String(localized: "%lld workouts"), Int64(badge.threshold))
        case .weeklyGoal: String(localized: "First weekly goal")
        case .weeklyStreak: String(format: String(localized: "%lld-week streak"), Int64(badge.threshold))
        }
    }

    private var progressText: String {
        "\(Int((badge.progress * 100).rounded()))%"
    }
}
