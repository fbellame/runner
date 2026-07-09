import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \DayLedger.date, order: .forward) private var ledgers: [DayLedger]
    @Query(sort: \WorkoutRec.start, order: .reverse) private var workouts: [WorkoutRec]
    @State private var chartRange = 7
    @State private var selectedDay: SelectedDay?

    private var snapshots: [DaySnapshot] {
        ledgers.map { DaySnapshot(date: $0.date, points: $0.totalPoints, isGold: $0.isGold) }
    }

    private var workoutSummaries: [ActivityWorkoutSummary] {
        workouts.map(ActivityWorkoutSummary.init(workout:))
    }

    var body: some View {
        NavigationStack {
            content
            .background(Color.rBackground)
            .navigationTitle(String(localized: "History"))
            .navigationDestination(item: $selectedDay) { selection in
                DayDetailView(date: selection.date)
            }
            .navigationDestination(for: ActivityType.self) { type in
                ActivityDetailView(type: type)
            }
            .navigationDestination(for: InsightsRoute.self) { route in
                InsightsView(initialType: route.initialType)
            }
        }
    }

    private var content: some View {
        let summaries = workoutSummaries
        let totals = ActivityStats.lifetimeTotals(summaries)
        let mostUsedType = mostUsedType(in: totals)

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MicroLabel(text: String(localized: "Last 52 weeks"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HeatmapView(weeks: HistoryMath.heatmapWeeks(days: snapshots,
                                                                today: .now,
                                                                weekCount: 52,
                                                                calendar: .current),
                                goal: model.dailyGoal,
                                onSelect: { selectedDay = SelectedDay(date: $0) })
                }

                insightsEntryCard(initialType: mostUsedType)
                chartSection
                lifetimeTotalsSection(totals)
                activityTypesSection(totals)
                recordsSection(summaries: summaries)
                milestonesSection(totals)
                workoutsSection
                Spacer(minLength: 90)
            }
            .padding(.horizontal, 18)
        }
    }

    private func insightsEntryCard(initialType: ActivityType) -> some View {
        NavigationLink(value: InsightsRoute(initialType: initialType)) {
            SurfaceCard {
                HStack(spacing: 12) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.rLime)
                        .frame(width: 42, height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.rLime.opacity(0.14))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.rLime.opacity(0.45), lineWidth: 1))
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Insights"))
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(String(localized: "Trends, pace & consistency"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.rTextSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.rLime)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func mostUsedType(in totals: LifetimeTotals) -> ActivityType {
        var bestType: ActivityType = .run
        var bestCount = 0

        for type in ActivityType.allCases {
            let count = totals.perType[type]?.workouts ?? 0
            if count > bestCount {
                bestType = type
                bestCount = count
            }
        }

        return bestCount > 0 ? bestType : .run
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(String(localized: "Range"), selection: $chartRange) {
                Text(String(localized: "Week")).tag(7)
                Text(String(localized: "Month")).tag(30)
                Text(String(localized: "Year")).tag(365)
            }
            .pickerStyle(.segmented)

            Chart {
                ForEach(HistoryMath.dailySeries(days: snapshots,
                                                lastN: chartRange,
                                                endingAt: .now,
                                                calendar: .current),
                        id: \.date) { day in
                    BarMark(x: .value("Day", day.date, unit: .day),
                            y: .value("Points", day.points))
                        .foregroundStyle(day.isGold ? Color.rLime : Color.rLime.opacity(0.35))
                        .cornerRadius(3)
                }
                RuleMark(y: .value("Goal", model.dailyGoal))
                    .foregroundStyle(Color.rOrange.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .frame(height: 180)
            .chartYAxis { AxisMarks(position: .trailing) }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            let originX = geo[proxy.plotAreaFrame].origin.x
                            if let date: Date = proxy.value(atX: location.x - originX) {
                                selectedDay = SelectedDay(date: Calendar.current.startOfDay(for: date))
                            }
                        }
                }
            }
        }
    }

    private func lifetimeTotalsSection(_ totals: LifetimeTotals) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: String(localized: "Lifetime totals"))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(label: String(localized: "Distance"),
                         value: Format.km(totals.distanceMeters),
                         accent: .rLime)
                StatTile(label: String(localized: "Time"),
                         value: Format.duration(totals.movingSeconds),
                         accent: .rTeal)
                StatTile(label: String(localized: "Calories"),
                         value: "\(Int(totals.calories.rounded())) \(String(localized: "kcal"))",
                         accent: .rOrange)
                StatTile(label: String(localized: "Workouts"),
                         value: "\(totals.workouts)",
                         accent: .rPurple)
                if totals.co2SavedGrams > 0 {
                    StatTile(label: String(localized: "CO₂ saved"),
                             value: Format.co2(grams: totals.co2SavedGrams),
                             accent: .rTeal)
                }
            }
        }
    }

    private func activityTypesSection(_ totals: LifetimeTotals) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: String(localized: "Activity types"))
            HStack(spacing: 10) {
                ForEach(ActivityType.allCases, id: \.self) { type in
                    NavigationLink(value: type) {
                        activityTypeCard(type: type,
                                         totals: totals.perType[type] ?? (distanceMeters: 0, workouts: 0))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func activityTypeCard(type: ActivityType,
                                  totals: (distanceMeters: Double, workouts: Int)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(type.emoji)
                .font(.system(size: 24))
            Text(type.localizedName)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("\(String(localized: "\(totals.workouts) sessions")) · \(Format.km(totals.distanceMeters))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.rTextSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.rSurface)
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(type.accent.opacity(0.75), lineWidth: 1))
        )
    }

    private func recordsSection(summaries: [ActivityWorkoutSummary]) -> some View {
        let workoutByID = Dictionary(uniqueKeysWithValues: workouts.map { ($0.id, $0) })
        let bestDay = ledgers.max { $0.totalPoints < $1.totalPoints }
        let bestStreak = ledgers.max { $0.streakAfter < $1.streakAfter }

        return SurfaceCard {
            VStack(spacing: 10) {
                MicroLabel(text: String(localized: "Records"))
                recordRow("🏆",
                          String(localized: "Best day"),
                          "\(bestDay?.totalPoints ?? 0) pts",
                          date: bestDay?.date,
                          accent: .rLime)
                recordRow("🔥",
                          String(localized: "Best streak"),
                          String(localized: "\(bestStreak?.streakAfter ?? 0) days"),
                          date: bestStreak?.date,
                          accent: .rOrange)
                workoutRecordRow("🏃",
                                 String(localized: "Longest run"),
                                 typedRecord(.longestDistance, type: .run, summaries: summaries),
                                 value: { Format.km($0.value, estimated: $0.distanceEstimated) },
                                 workoutByID: workoutByID)
                workoutRecordRow("🚶",
                                 String(localized: "Longest walk"),
                                 typedRecord(.longestDistance, type: .walk, summaries: summaries),
                                 value: { Format.km($0.value, estimated: $0.distanceEstimated) },
                                 workoutByID: workoutByID)
                workoutRecordRow("🚴",
                                 String(localized: "Longest ride"),
                                 typedRecord(.longestDistance, type: .bike, summaries: summaries),
                                 value: { Format.km($0.value, estimated: $0.distanceEstimated) },
                                 workoutByID: workoutByID)
                workoutRecordRow("⚡️",
                                 String(localized: "Fastest 1 km"),
                                 fastestOneKilometerRecord(summaries: summaries),
                                 value: { Format.pace($0.value) },
                                 workoutByID: workoutByID)
            }
        }
    }

    private func typedRecord(_ kind: RecordKind, type: ActivityType,
                             summaries: [ActivityWorkoutSummary]) -> PersonalRecord? {
        ActivityStats.typeRecords(summaries, type: type).first { $0.kind == kind }
    }

    private func fastestOneKilometerRecord(summaries: [ActivityWorkoutSummary]) -> PersonalRecord? {
        ActivityType.allCases
            .compactMap { typedRecord(.fastestOneKilometer, type: $0, summaries: summaries) }
            .min { $0.value < $1.value }
    }

    @ViewBuilder
    private func workoutRecordRow(_ emoji: String, _ label: String, _ record: PersonalRecord?,
                                  value: (PersonalRecord) -> String,
                                  workoutByID: [UUID: WorkoutRec]) -> some View {
        if let record, let id = record.workoutID, let workout = workoutByID[id] {
            NavigationLink {
                WorkoutDetailView(workout: workout)
            } label: {
                recordRow(emoji,
                          label,
                          value(record),
                          date: record.date,
                          accent: workout.type.accent,
                          showsChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            recordRow(emoji, label, "—", date: nil, accent: .rTextSecondary)
        }
    }

    private func recordRow(_ emoji: String, _ label: String, _ value: String,
                           date: Date?, accent: Color,
                           showsChevron: Bool = false) -> some View {
        HStack {
            Text(emoji)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                if let date {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(Color.rTextSecondary)
                }
            }
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.rTextSecondary)
            }
        }
    }

    private func milestonesSection(_ totals: LifetimeTotals) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: String(localized: "Milestones"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(ActivityStats.milestones(totals).enumerated()), id: \.offset) { _, milestone in
                        milestoneChip(milestone)
                    }
                }
            }
        }
    }

    private func milestoneChip(_ milestone: Milestone) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(milestone.earned ? "✓" : "•")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                Text(milestoneTitle(milestone))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            if !milestone.earned && milestone.progress > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.rBorder)
                        Capsule()
                            .fill(Color.rLime)
                            .frame(width: geo.size.width * milestone.progress)
                    }
                }
                .frame(height: 4)
            }
        }
        .foregroundStyle(milestone.earned ? Color.rLime : .white)
        .frame(width: 112, height: 48, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.rSurface))
        .overlay(Capsule().stroke(milestone.earned ? Color.rLime : Color.rBorder,
                                  lineWidth: 1))
        .shadow(color: milestone.earned ? Color.rLime.opacity(0.35) : .clear,
                radius: milestone.earned ? 8 : 0)
    }

    private func milestoneTitle(_ milestone: Milestone) -> String {
        switch milestone.kind {
        case .totalDistance:
            "\(Int(milestone.threshold)) km"
        case .workoutCount:
            String(localized: "\(Int(milestone.threshold)) workouts")
        }
    }

    private var workoutsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: String(localized: "Workouts"))
            if workouts.isEmpty {
                SurfaceCard {
                    Text(String(localized: "No workouts yet — hit the ▶ button!"))
                        .font(.subheadline)
                        .foregroundStyle(Color.rTextSecondary)
                }
            }
            ForEach(workouts) { workout in
                NavigationLink {
                    WorkoutDetailView(workout: workout)
                } label: {
                    WorkoutRowCard(workout: workout)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// A tapped calendar day, wrapped so `.navigationDestination(item:)` has an
// Identifiable without a retroactive conformance on the stdlib `Date` type.
struct SelectedDay: Hashable {
    let date: Date
}

struct InsightsRoute: Hashable {
    let initialType: ActivityType
}

extension ActivityWorkoutSummary {
    init(workout: WorkoutRec) {
        self.init(id: workout.id,
                  type: workout.type,
                  date: workout.start,
                  distanceMeters: workout.distanceMeters,
                  distanceEstimated: workout.distanceEstimated,
                  movingSeconds: workout.movingSeconds,
                  points: workout.points,
                  calories: workout.calories,
                  splitSeconds: workout.splitSeconds,
                  hasRoute: workout.routeData != nil,
                  co2SavedGrams: workout.co2SavedGrams)
    }
}

struct WorkoutRowCard: View {
    let workout: WorkoutRec

    var body: some View {
        SurfaceCard {
            HStack {
                Text(workout.type.emoji)
                    .font(.system(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(workout.type.localizedName) · \(Format.km(workout.distanceMeters, estimated: workout.distanceEstimated))")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(workout.start.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(Color.rTextSecondary)
                }
                Spacer()
                Text("+\(workout.points)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(workout.type.accent)
            }
        }
    }
}
