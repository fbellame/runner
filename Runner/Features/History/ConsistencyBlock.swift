import SwiftUI
import Charts

/// Sessions-per-week sparkline over 52 weeks, week streaks, and a gap callout.
struct ConsistencyBlock: View {
    let type: ActivityType
    let summaries: [ActivityWorkoutSummary]

    private static let gapCalloutDays = 7
    private static let sparklineWeeks = 52

    var body: some View {
        let stats = HubMath.consistency(summaries, type: type,
                                        asOf: .now, calendar: .current)
        let weekly = InsightsMath.weeklySeries(summaries, type: type,
                                               weeks: Self.sparklineWeeks,
                                               endingAt: .now, calendar: .current)

        VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: String(localized: "Consistency"))
            sparkline(weekly)
            HStack(spacing: 10) {
                StatTile(label: String(localized: "Current streak"),
                         value: weeksValue(stats.currentWeekStreak),
                         accent: stats.currentWeekStreak > 0 ? type.accent : .rTextSecondary)
                StatTile(label: String(localized: "Longest streak"),
                         value: weeksValue(stats.longestWeekStreak),
                         accent: .white)
            }
            if let days = stats.daysSinceLast, days > Self.gapCalloutDays {
                gapCallout(days: days)
            }
        }
    }

    private func sparkline(_ weekly: [WeeklyInsightPoint]) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 6) {
                MicroLabel(text: String(localized: "Sessions per week · last 52 weeks"))
                Chart {
                    ForEach(weekly) { point in
                        BarMark(x: .value(String(localized: "Week"), point.weekStart, unit: .weekOfYear),
                                y: .value(String(localized: "Sessions"), point.sessions))
                            .foregroundStyle(point.sessions > 0
                                             ? type.accent
                                             : Color.rTextSecondary.opacity(0.2))
                    }
                }
                .frame(height: 60)
                .chartYAxis(.hidden)
                .chartXAxis(.hidden)
            }
        }
    }

    private func gapCallout(days: Int) -> some View {
        SurfaceCard {
            Text(String(format: gapFormat, Int64(days)))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.rOrange)
        }
    }

    private var gapFormat: String {
        switch type {
        case .run:
            String(localized: "Last run: %lld days ago")
        case .walk:
            String(localized: "Last walk: %lld days ago")
        case .bike:
            String(localized: "Last ride: %lld days ago")
        }
    }

    private func weeksValue(_ weeks: Int) -> String {
        String(format: String(localized: "%lld wk"), Int64(weeks))
    }
}
