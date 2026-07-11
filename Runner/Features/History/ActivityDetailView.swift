import SwiftUI
import SwiftData
import Charts

struct ActivityDetailView: View {
    @Environment(AppModel.self) private var model
    let type: ActivityType
    @Query(sort: \WorkoutRec.start, order: .reverse) private var workouts: [WorkoutRec]
    @State private var chartRange = 7
    @State private var showsGoalEditor = false

    init(type: ActivityType) {
        self.type = type
    }

    private var typeWorkouts: [WorkoutRec] {
        workouts.filter { $0.type == type }
    }

    private var typeSummaries: [ActivityWorkoutSummary] {
        typeWorkouts.map(ActivityWorkoutSummary.init(workout:))
    }

    var body: some View {
        let summaries = typeSummaries
        let stats = ActivityStats.typeStats(summaries, type: type, calendar: .current)
        let records = ActivityStats.typeRecords(summaries, type: type)
        let workoutByID = Dictionary(uniqueKeysWithValues: typeWorkouts.map { ($0.id, $0) })
        let goalProgress = currentGoalProgress(summaries)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(stats: stats, goalProgress: goalProgress)
                totalsGrid(stats: stats)
                paceGrid(stats: stats)
                distanceChart(stats: stats)
                recordsSection(records: records, workoutByID: workoutByID)
                recentSessions
                Spacer(minLength: 60)
            }
            .padding(18)
        }
        .background(Color.rBackground)
        .navigationTitle(type.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsGoalEditor) {
            WeeklyDistanceGoalSheet(type: type,
                                    currentGoal: model.weeklyDistanceGoal(for: type)) { value in
                model.setWeeklyDistanceGoal(value, for: type)
            }
        }
    }

    private func header(stats: TypeStats,
                        goalProgress: ActivityDistanceGoalProgress?) -> some View {
        SurfaceCard {
            HStack(spacing: 12) {
                Text(type.emoji)
                    .font(.system(size: 42))
                VStack(alignment: .leading, spacing: 4) {
                    Text(type.localizedName)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(type.accent)
                    Text("\(String(localized: "\(stats.sessions) sessions")) · \(Format.km(stats.totalDistanceMeters))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.rTextSecondary)
                }
                Spacer()
                Button {
                    showsGoalEditor = true
                } label: {
                    if let goalProgress {
                        VStack(spacing: 5) {
                            WeeklyDistanceGoalRing(
                                fraction: goalProgress.fraction,
                                accent: type.accent,
                                centerText: "\(Int((goalProgress.fraction * 100).rounded()))%")
                            Text(DistanceGoalFormat.progress(goalProgress))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(type.accent)
                                .lineLimit(1)
                        }
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 24, weight: .semibold))
                            Text(String(localized: "Set weekly goal"))
                                .font(.system(size: 10, weight: .semibold))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(type.accent)
                        .frame(width: 78)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: goalProgress == nil
                    ? "Set weekly goal" : "Edit weekly goal"))
            }
        }
    }

    private func currentGoalProgress(_ summaries: [ActivityWorkoutSummary])
    -> ActivityDistanceGoalProgress? {
        guard let goal = model.weeklyDistanceGoal(for: type) else { return nil }
        return GoalsMath.currentWeekDistance(summaries,
                                             goals: [type: goal],
                                             asOf: .now,
                                             calendar: .current).first
    }

    private func totalsGrid(stats: TypeStats) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatTile(label: String(localized: "Sessions"),
                     value: "\(stats.sessions)",
                     accent: type.accent)
            StatTile(label: String(localized: "Distance"),
                     value: Format.km(stats.totalDistanceMeters),
                     accent: .rLime)
            StatTile(label: String(localized: "Time"),
                     value: Format.duration(stats.totalMovingSeconds),
                     accent: .rTeal)
            StatTile(label: String(localized: "Calories"),
                     value: "\(Int(stats.totalCalories.rounded())) \(String(localized: "kcal"))",
                     accent: .rOrange)
        }
    }

    private func paceGrid(stats: TypeStats) -> some View {
        HStack(spacing: 10) {
            StatTile(label: String(localized: "Best pace"),
                     value: Format.pace(stats.bestPaceSecPerKm),
                     accent: type.accent)
            StatTile(label: String(localized: "Average pace"),
                     value: Format.pace(stats.avgPaceSecPerKm),
                     accent: .white)
        }
    }

    private func distanceChart(stats: TypeStats) -> some View {
        let points = chartPoints(from: stats.weeklyDistance)

        return VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: String(localized: "Distance by week"))
            Picker(String(localized: "Range"), selection: $chartRange) {
                Text(String(localized: "Week")).tag(7)
                Text(String(localized: "Month")).tag(30)
            }
            .pickerStyle(.segmented)

            Chart {
                ForEach(points) { point in
                    BarMark(x: .value(String(localized: "Week"), point.weekStart, unit: .weekOfYear),
                            y: .value(String(localized: "Distance"), point.meters / 1000.0))
                        .foregroundStyle(type.accent)
                        .cornerRadius(3)
                }
            }
            .frame(height: 150)
            .chartYAxis { AxisMarks(position: .trailing) }
        }
    }

    private func recordsSection(records: [PersonalRecord],
                                workoutByID: [UUID: WorkoutRec]) -> some View {
        SurfaceCard {
            VStack(spacing: 10) {
                MicroLabel(text: String(localized: "Records"))
                ForEach(records, id: \.kind) { record in
                    if let id = record.workoutID, let workout = workoutByID[id] {
                        NavigationLink {
                            WorkoutDetailView(workout: workout)
                        } label: {
                            RecordRow(record: record, accent: type.accent, showsChevron: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        RecordRow(record: record, accent: .rTextSecondary)
                    }
                }
            }
        }
    }

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: String(localized: "Recent sessions"))
            if typeWorkouts.isEmpty {
                SurfaceCard {
                    Text(String(localized: "No workouts yet — hit the ▶ button!"))
                        .font(.subheadline)
                        .foregroundStyle(Color.rTextSecondary)
                }
            }
            ForEach(typeWorkouts) { workout in
                NavigationLink {
                    WorkoutDetailView(workout: workout)
                } label: {
                    WorkoutRowCard(workout: workout)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func chartPoints(from weeklyDistance: [(weekStart: Date, meters: Double)])
    -> [WeeklyDistancePoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let cutoff = calendar.date(byAdding: .day, value: -chartRange, to: today) ?? today
        return weeklyDistance
            .filter { $0.weekStart >= cutoff }
            .map { WeeklyDistancePoint(weekStart: $0.weekStart, meters: $0.meters) }
    }
}

private struct WeeklyDistancePoint: Identifiable {
    let weekStart: Date
    let meters: Double
    var id: Date { weekStart }
}
