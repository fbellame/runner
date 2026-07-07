import SwiftUI
import SwiftData
import UIKit

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \DayLedger.date, order: .reverse) private var ledgers: [DayLedger]
    @Query(sort: \WorkoutRec.start, order: .reverse) private var workouts: [WorkoutRec]
    @State private var celebrate = false
    // Decoded once when today's workouts change, not twice per body pass.
    @State private var latestRoute: [RoutePoint] = []

    private var today: DayLedger? {
        ledgers.first { Calendar.current.isDateInToday($0.date) }
    }

    private var todayWorkouts: [WorkoutRec] {
        workouts.filter { Calendar.current.isDateInToday($0.start) }
    }

    private var streakEnteringToday: Int {
        ledgers.first { !Calendar.current.isDateInToday($0.date) }?.streakAfter ?? 0
    }

    private func rebuildLatestRoute() {
        guard let data = todayWorkouts.first(where: { $0.routeData != nil })?.routeData else {
            latestRoute = []
            return
        }
        latestRoute = [RoutePoint].decode(data)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                pointsBlock
                breakdown
                if !latestRoute.isEmpty {
                    miniMap
                }
                if (today?.steps ?? 0) == 0 {
                    // Never silent zeros: a read denial is indistinguishable from no
                    // data in HealthKit, so zero steps always comes with an explainer.
                    healthExplainerCard
                }
                if let storeError = model.storeFailureMessage {
                    SurfaceCard {
                        Label(String(localized: "Storage is unavailable (\(storeError)). Nothing recorded now will survive an app restart."),
                              systemImage: "externaldrive.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(Color.rOrange)
                    }
                }
                if let error = model.sync.lastError {
                    SurfaceCard {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.rOrange)
                    }
                }
                Spacer(minLength: 90)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        .background(Color.rBackground)
        .onAppear(perform: rebuildLatestRoute)
        .onChange(of: workouts.map(\.id)) { _, _ in rebuildLatestRoute() }
        .overlay {
            if celebrate {
                CelebrationBurst()
            }
        }
        .onChange(of: today?.isGold ?? false) { was, isNow in
            if !was && isNow {
                celebrate = true
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    celebrate = false
                }
            }
        }
        .refreshable {
            await model.sync.syncNow()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            MicroLabel(text: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            if streakEnteringToday > 0 || (today?.isGold ?? false) {
                let streak = today?.isGold == true ? (today?.streakAfter ?? 0) : streakEnteringToday
                Text("🔥 \(streak)-day streak · ×\((today?.multiplier ?? 1).formatted(.number.precision(.fractionLength(2))))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.rOrange)
            }
        }
        .padding(.top, 10)
    }

    private var pointsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                GlowNumber(value: today?.totalPoints ?? 0, unitLabel: "PTS")
                Spacer()
                if today?.isGold == true {
                    Text(String(localized: "GOLD DAY"))
                        .font(.system(size: 11, weight: .black))
                        .tracking(1.5)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.rLime.opacity(0.15)))
                        .overlay(Capsule().stroke(Color.rLime, lineWidth: 1))
                        .foregroundStyle(Color.rLime)
                }
            }
            GoalBar(points: today?.totalPoints ?? 0, goal: model.dailyGoal)
            Text(String(localized: "Goal: \(model.dailyGoal) pts"))
                .font(.caption)
                .foregroundStyle(Color.rTextSecondary)
        }
    }

    private var breakdown: some View {
        SurfaceCard {
            VStack(spacing: 0) {
                breakdownRow(emoji: "👟",
                             label: String(localized: "\((today?.steps ?? 0).formatted()) steps"),
                             value: today?.stepPoints ?? 0,
                             accent: .rLime)
                ForEach(todayWorkouts) { workout in
                    Divider().overlay(Color.rBorder)
                    breakdownRow(emoji: workout.type.emoji,
                                 label: "\(workout.type.localizedName) · \(Format.km(workout.distanceMeters))",
                                 value: workout.points,
                                 accent: workout.type.accent)
                }
                if let today, today.multiplier > 1.0 {
                    Divider().overlay(Color.rBorder)
                    HStack {
                        Text("🔥 \(String(localized: "Streak bonus"))")
                            .font(.system(size: 14))
                        Spacer()
                        Text("×\(today.multiplier.formatted(.number.precision(.fractionLength(2))))")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.rOrange)
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func breakdownRow(emoji: String, label: String, value: Int, accent: Color) -> some View {
        HStack {
            Text(emoji)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.white)
            Spacer()
            Text("+\(value)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
        }
        .padding(.vertical, 10)
    }

    private var healthExplainerCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(String(localized: "No steps from Apple Health yet. If Runner was denied access, allow reading under Health → Sharing → Apps."),
                      systemImage: "heart.text.square")
                    .font(.caption)
                    .foregroundStyle(Color.rTextSecondary)
                Button(String(localized: "Open Health sharing")) {
                    if let url = URL(string: "x-apple-health://") {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.rLime)
            }
        }
    }

    private var miniMap: some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: String(localized: "Latest parcours"))
            RouteMapView(points: latestRoute)
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.rBorder, lineWidth: 1))
        }
    }
}

struct CelebrationBurst: View {
    @State private var scale: CGFloat = 0.4
    @State private var opacity: Double = 0.9

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color.rLime.opacity(0.5), .clear],
                                 center: .center,
                                 startRadius: 10,
                                 endRadius: 240))
            .scaleEffect(scale)
            .opacity(opacity)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 1.4)) {
                    scale = 2.4
                    opacity = 0
                }
                Haptics.goalReached()
            }
    }
}
