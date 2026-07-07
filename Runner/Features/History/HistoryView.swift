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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MicroLabel(text: String(localized: "Last 13 weeks"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HeatmapView(weeks: HistoryMath.heatmapWeeks(days: snapshots,
                                                                    today: .now,
                                                                    weekCount: 13,
                                                                    calendar: .current),
                                    goal: model.dailyGoal,
                                    onSelect: { selectedDay = SelectedDay(date: $0) })
                    }

                    chartSection
                    recordsSection
                    workoutsSection
                    Spacer(minLength: 90)
                }
                .padding(.horizontal, 18)
            }
            .background(Color.rBackground)
            .navigationTitle(String(localized: "History"))
            .navigationDestination(item: $selectedDay) { selection in
                DayDetailView(date: selection.date)
            }
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(String(localized: "Range"), selection: $chartRange) {
                Text(String(localized: "Week")).tag(7)
                Text(String(localized: "Month")).tag(30)
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

    private var recordsSection: some View {
        SurfaceCard {
            VStack(spacing: 8) {
                MicroLabel(text: String(localized: "Records"))
                recordRow("🏆", String(localized: "Best day"),
                          "\(ledgers.map(\.totalPoints).max() ?? 0) pts")
                recordRow("🔥", String(localized: "Best streak"),
                          String(localized: "\(ledgers.map(\.streakAfter).max() ?? 0) days"))
                recordRow("🏃", String(localized: "Longest run"),
                          Format.km(workouts.filter { $0.type == .run }.map(\.distanceMeters).max() ?? 0))
                recordRow("🚴", String(localized: "Longest ride"),
                          Format.km(workouts.filter { $0.type == .bike }.map(\.distanceMeters).max() ?? 0))
            }
        }
    }

    private func recordRow(_ emoji: String, _ label: String, _ value: String) -> some View {
        HStack {
            Text(emoji)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rLime)
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
                    SurfaceCard {
                        HStack {
                            Text(workout.type.emoji)
                                .font(.system(size: 22))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(workout.type.localizedName) · \(Format.km(workout.distanceMeters))")
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
