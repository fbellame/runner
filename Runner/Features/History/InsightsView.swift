import SwiftUI
import SwiftData
import Charts

struct InsightsView: View {
    @Query(sort: \WorkoutRec.start, order: .reverse) private var workouts: [WorkoutRec]
    @State private var selectedType: ActivityType

    private let chartWeeks = 12

    init(initialType: ActivityType) {
        _selectedType = State(initialValue: initialType)
    }

    private var workoutSummaries: [ActivityWorkoutSummary] {
        workouts.map(ActivityWorkoutSummary.init(workout:))
    }

    var body: some View {
        let summaries = workoutSummaries
        let summary = InsightsMath.summary(summaries,
                                           type: selectedType,
                                           endingAt: .now,
                                           calendar: .current)
        let comparison = InsightsMath.periodComparison(summaries,
                                                       type: selectedType,
                                                       weeksPerPeriod: 4,
                                                       endingAt: .now,
                                                       calendar: .current)
        let series = InsightsMath.weeklySeries(summaries,
                                               type: selectedType,
                                               weeks: chartWeeks,
                                               endingAt: .now,
                                               calendar: .current)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                typePicker
                summaryCard(summary)
                deltaSection(comparison)
                distanceChart(series)
                paceChart(series)
                Spacer(minLength: 60)
            }
            .padding(18)
        }
        .background(Color.rBackground)
        .navigationTitle(String(localized: "Insights"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var typePicker: some View {
        Picker(String(localized: "Activity types"), selection: $selectedType) {
            ForEach(ActivityType.allCases, id: \.self) { type in
                Text("\(type.emoji) \(type.localizedName)").tag(type)
            }
        }
        .pickerStyle(.segmented)
    }

    private func summaryCard(_ summary: InsightSummary) -> some View {
        SurfaceCard {
            if summary.hasEnoughData {
                VStack(alignment: .leading, spacing: 10) {
                    Text(frequencySentence(summary))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    if let paceSentence = paceSentence(summary) {
                        Text(paceSentence)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.rTextSecondary)
                    }
                }
            } else {
                Text(String(localized: "Not enough data yet — keep at it!"))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.rTextSecondary)
            }
        }
    }

    private func deltaSection(_ comparison: PeriodComparison) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: String(localized: "vs previous 4 weeks"))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 10) {
                let distance = percentDeltaValue(comparison.distanceDeltaFraction)
                StatTile(label: String(localized: "Distance"),
                         value: distance.value,
                         accent: distance.accent)

                let sessions = sessionsDeltaValue(comparison)
                StatTile(label: String(localized: "Sessions"),
                         value: sessions.value,
                         accent: sessions.accent)

                let time = percentDeltaValue(comparison.movingSecondsDeltaFraction)
                StatTile(label: String(localized: "Time"),
                         value: time.value,
                         accent: time.accent)
            }
        }
    }

    private func distanceChart(_ series: [WeeklyInsightPoint]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: String(localized: "Distance by week"))
            Chart {
                ForEach(series) { point in
                    BarMark(x: .value(String(localized: "Week"), point.weekStart, unit: .weekOfYear),
                            y: .value(String(localized: "Distance"), point.distanceMeters / 1000.0))
                        .foregroundStyle(selectedType.accent)
                        .cornerRadius(3)
                }
            }
            .frame(height: 150)
            .chartYAxis { AxisMarks(position: .trailing) }
        }
    }

    @ViewBuilder
    private func paceChart(_ series: [WeeklyInsightPoint]) -> some View {
        let points = pacePoints(from: series)

        VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: String(localized: "Pace by week (lower = faster)"))
            if points.count < 2 {
                SurfaceCard {
                    Text(String(localized: "Not enough pace data yet"))
                        .font(.subheadline)
                        .foregroundStyle(Color.rTextSecondary)
                }
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value(String(localized: "Week"), point.weekStart, unit: .weekOfYear),
                                 y: .value(String(localized: "Pace"), point.paceSecPerKm))
                            .foregroundStyle(selectedType.accent)
                        PointMark(x: .value(String(localized: "Week"), point.weekStart, unit: .weekOfYear),
                                  y: .value(String(localized: "Pace"), point.paceSecPerKm))
                            .foregroundStyle(selectedType.accent)
                    }
                }
                .frame(height: 150)
                .chartYAxis { AxisMarks(position: .trailing) }
            }
        }
    }

    private func frequencySentence(_ summary: InsightSummary) -> String {
        var sentence = String(format: frequencyFormat(for: selectedType),
                              oneDecimal(summary.sessionsPerWeek))
        if summary.sessionsPerWeekPrevious > 0 {
            if summary.sessionsPerWeek > summary.sessionsPerWeekPrevious {
                sentence += String(format: String(localized: ", up from %@"),
                                   oneDecimal(summary.sessionsPerWeekPrevious))
            } else if summary.sessionsPerWeek < summary.sessionsPerWeekPrevious {
                sentence += String(format: String(localized: ", down from %@"),
                                   oneDecimal(summary.sessionsPerWeekPrevious))
            }
        }
        return sentence
    }

    private func paceSentence(_ summary: InsightSummary) -> String? {
        switch summary.paceTrend {
        case .improving:
            guard let delta = summary.paceDeltaSecPerKm else { return nil }
            return String(format: String(localized: "Pace is improving — %@ faster than the previous 4 weeks."),
                          secondsPerKilometer(abs(delta)))
        case .declining:
            guard let delta = summary.paceDeltaSecPerKm else { return nil }
            return String(format: String(localized: "Pace is declining — %@ slower than the previous 4 weeks."),
                          secondsPerKilometer(abs(delta)))
        case .steady:
            return String(localized: "Pace is holding steady.")
        case .insufficientData:
            return nil
        }
    }

    private func frequencyFormat(for type: ActivityType) -> String {
        switch type {
        case .run:
            String(localized: "You're running %@× per week")
        case .walk:
            String(localized: "You're walking %@× per week")
        case .bike:
            String(localized: "You're biking %@× per week")
        }
    }

    private func percentDeltaValue(_ delta: Double?) -> (value: String, accent: Color) {
        guard let delta else {
            return (String(localized: "new"), Color.rTextSecondary)
        }

        if delta > 0 {
            return ("▲ \(percent(abs(delta)))", Color.rLime)
        } else if delta < 0 {
            return ("▼ \(percent(abs(delta)))", Color.rOrange)
        }
        return (percent(0), Color.rTextSecondary)
    }

    private func sessionsDeltaValue(_ comparison: PeriodComparison) -> (value: String, accent: Color) {
        guard comparison.sessions.previous > 0 else {
            return (String(localized: "new"), Color.rTextSecondary)
        }

        let delta = comparison.sessionsPerWeekDelta
        if delta > 0 {
            return ("▲ \(perWeek(abs(delta)))", Color.rLime)
        } else if delta < 0 {
            return ("▼ \(perWeek(abs(delta)))", Color.rOrange)
        }
        return (perWeek(0), Color.rTextSecondary)
    }

    private func pacePoints(from series: [WeeklyInsightPoint]) -> [PaceInsightPoint] {
        series.compactMap { point in
            guard let pace = point.avgPaceSecPerKm else { return nil }
            return PaceInsightPoint(weekStart: point.weekStart, paceSecPerKm: pace)
        }
    }

    private func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func perWeek(_ value: Double) -> String {
        String(format: String(localized: "%@/wk"), oneDecimal(value))
    }

    private func secondsPerKilometer(_ value: Double) -> String {
        String.localizedStringWithFormat(String(localized: "%llds/km"),
                                         Int64(value.rounded()))
    }
}

private struct PaceInsightPoint: Identifiable {
    let weekStart: Date
    let paceSecPerKm: Double

    var id: Date { weekStart }
}
