import SwiftUI
import SwiftData
import UIKit
import Charts

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \DayLedger.date, order: .reverse) private var ledgers: [DayLedger]
    @Query(sort: \WorkoutRec.start, order: .reverse) private var workouts: [WorkoutRec]
    @State private var celebrate = false
    // Decoded once when today's workouts change, not twice per body pass.
    @State private var latestRoute: [RoutePoint] = []
    @State private var trendMode = 0   // 0 = points, 1 = calories

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
        @Bindable var model = model
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                pointsBlock
                breakdown
                statStrip
                if model.profile.currentMetrics().weightKg != nil {
                    caloriesCard
                } else {
                    addWeightCard
                }
                weeklyRecapCard
                trendCard
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
        .alert(String(localized: "Review your profile"), isPresented: $model.showProfilePrompt) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "Runner now estimates calories from your body metrics. Check them under Settings → Profile."))
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
                                 label: "\(workout.type.localizedName) · \(Format.km(workout.distanceMeters, estimated: workout.distanceEstimated))",
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

    private var todayEnergyInputs: [WorkoutEnergyInput] {
        todayWorkouts.map { WorkoutEnergyInput(type: $0.type, distanceMeters: $0.distanceMeters,
                                               movingSeconds: $0.movingSeconds) }
    }

    private var statStrip: some View {
        HStack(spacing: 10) {
            statTile("🔥", (today?.activeCalories ?? 0) > 0
                     ? "\(Int((today?.activeCalories ?? 0).rounded()))"
                     : "—", String(localized: "kcal"))
            statTile("📏", Format.km(today?.distanceMeters ?? 0), String(localized: "today"))
            statTile("⏱️", Format.duration(today?.activeSeconds ?? 0), String(localized: "active"))
        }
    }

    private func statTile(_ emoji: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 3) {
            Text(emoji).font(.system(size: 18))
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text(unit.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1)
                .foregroundStyle(Color.rTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.rSurface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.rBorder, lineWidth: 1))
    }

    private var caloriesCard: some View {
        let breakdown = CalorieEngine.dayCalories(steps: today?.steps ?? 0,
                                                  workouts: todayEnergyInputs,
                                                  metrics: model.profile.currentMetrics())
        return SurfaceCard {
            VStack(spacing: 0) {
                HStack {
                    Text("🔥 \(String(localized: "Calories burned"))").font(.system(size: 14))
                    Spacer()
                    Text("\(Int((breakdown?.total ?? 0).rounded())) \(String(localized: "kcal"))")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rOrange)
                }
                .padding(.vertical, 10)
                Divider().overlay(Color.rBorder)
                calorieRow(String(localized: "Everyday steps"),
                           Int((breakdown?.everydayKcal ?? 0).rounded()))
                ForEach(Array(todayWorkouts.enumerated()), id: \.element.id) { index, workout in
                    Divider().overlay(Color.rBorder)
                    calorieRow("\(workout.type.emoji) \(workout.type.localizedName) · \(Format.km(workout.distanceMeters, estimated: workout.distanceEstimated))",
                               Int((breakdown?.workoutKcal[safe: index] ?? 0).rounded()))
                }
                Text(String(localized: "Estimated from your body metrics.")).font(.system(size: 11))
                    .foregroundStyle(Color.rTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        }
    }

    private func calorieRow(_ label: String, _ kcal: Int) -> some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(.white)
            Spacer()
            Text("\(kcal) \(String(localized: "kcal"))")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rOrange)
        }
        .padding(.vertical, 10)
    }

    private var addWeightCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(String(localized: "Add your weight to see calories"), systemImage: "scalemass")
                    .font(.subheadline).foregroundStyle(.white)
                Text(String(localized: "Open Settings → Profile to add your weight, or allow Runner to read it from Apple Health."))
                    .font(.caption).foregroundStyle(Color.rTextSecondary)
            }
        }
    }

    private var weeklyRecap: WeeklyRecap {
        WeeklyRecapMath.recap(
            ledgers: ledgers.map { RecapLedgerDay(date: $0.date, totalPoints: $0.totalPoints, isGold: $0.isGold) },
            workouts: workouts.map(ActivityWorkoutSummary.init(workout:)),
            now: .now,
            calendar: .current)
    }

    @ViewBuilder
    private var weeklyRecapCard: some View {
        let recap = weeklyRecap
        if recap.hasActivity {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    MicroLabel(text: String(localized: "This week"))
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(recap.points)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("PTS")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.rTextSecondary)
                        Spacer()
                        let delta = recapDelta(recap.pointsDeltaFraction)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(delta.text)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(delta.accent)
                            MicroLabel(text: String(localized: "vs last week"))
                        }
                    }
                    HStack(spacing: 10) {
                        recapStat(Format.km(recap.distanceMeters), String(localized: "distance"))
                        recapStat("\(recap.sessions)", String(localized: "sessions"))
                    }
                    if let best = recap.bestRun {
                        HStack {
                            MicroLabel(text: String(localized: "Best run"))
                            Spacer()
                            Text("\(best.type.emoji) \(Format.km(best.distanceMeters)) · \(best.date.formatted(.dateTime.weekday(.abbreviated)))")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(best.type.accent)
                        }
                    }
                    if recap.goldDays > 0 {
                        Text(goldDaysText(recap.goldDays))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.rOrange)
                    }
                }
            }
        }
    }

    private func recapDelta(_ fraction: Double?) -> (text: String, accent: Color) {
        guard let fraction else {
            return (String(localized: "new"), Color.rTextSecondary)
        }
        let pct = abs(fraction).formatted(.percent.precision(.fractionLength(0)))
        if fraction > 0 { return ("▲ \(pct)", Color.rLime) }
        if fraction < 0 { return ("▼ \(pct)", Color.rOrange) }
        return (pct, Color.rTextSecondary)
    }

    private func recapStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(1)
                .foregroundStyle(Color.rTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func goldDaysText(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 gold day")
            : String(format: String(localized: "%lld gold days"), count)
    }

    private var last7: [DayLedger] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: .now))!
        return ledgers.filter { $0.date >= start }.sorted { $0.date < $1.date }
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MicroLabel(text: String(localized: "Last 7 days"))
                Spacer()
                Picker("", selection: $trendMode) {
                    Text(String(localized: "Points")).tag(0)
                    Text(String(localized: "Calories")).tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            Chart(last7, id: \.date) { day in
                BarMark(x: .value("Day", day.date, unit: .day),
                        y: .value("Value", trendMode == 0 ? Double(day.totalPoints) : day.activeCalories))
                    .foregroundStyle(trendMode == 0 ? Color.rLime : Color.rOrange)
                    .cornerRadius(3)
                if trendMode == 0 {
                    RuleMark(y: .value("Goal", model.dailyGoal))
                        .foregroundStyle(Color.rOrange.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .frame(height: 120)
            .chartYAxis { AxisMarks(position: .trailing) }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
