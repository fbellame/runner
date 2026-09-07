import SwiftUI
import Charts

/// Distance and pace progression with a 12W / 1Y / All range toggle.
/// 12W uses weekly buckets; 1Y and All use monthly buckets.
struct HubProgressionCharts: View {
    let type: ActivityType
    let summaries: [ActivityWorkoutSummary]

    @State private var range: HubChartRange = .twelveWeeks

    var body: some View {
        let points = chartPoints()

        VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: String(localized: "Progression"))
            Picker(String(localized: "Range"), selection: $range) {
                ForEach(HubChartRange.allCases, id: \.self) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)

            distanceChart(points)
            paceChart(points)
        }
    }

    private func distanceChart(_ points: [HubChartPoint]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: String(localized: "Distance"))
            Chart {
                ForEach(points) { point in
                    BarMark(x: .value(String(localized: "Date"), point.date, unit: range.calendarUnit),
                            y: .value(String(localized: "Distance"), point.distanceMeters / 1000.0))
                        .foregroundStyle(type.accent)
                        .cornerRadius(3)
                }
            }
            .frame(height: 150)
            .chartYAxis { AxisMarks(position: .trailing) }
        }
    }

    @ViewBuilder
    private func paceChart(_ points: [HubChartPoint]) -> some View {
        let paced = points.filter { $0.avgPaceSecPerKm != nil }

        VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: String(localized: "Pace (lower = faster)"))
            if paced.count < 2 {
                SurfaceCard {
                    Text(String(localized: "Not enough pace data yet"))
                        .font(.subheadline)
                        .foregroundStyle(Color.rTextSecondary)
                }
            } else {
                Chart {
                    ForEach(paced) { point in
                        LineMark(x: .value(String(localized: "Date"), point.date, unit: range.calendarUnit),
                                 y: .value(String(localized: "Pace"), point.avgPaceSecPerKm ?? 0))
                            .foregroundStyle(type.accent)
                        PointMark(x: .value(String(localized: "Date"), point.date, unit: range.calendarUnit),
                                  y: .value(String(localized: "Pace"), point.avgPaceSecPerKm ?? 0))
                            .foregroundStyle(type.accent)
                    }
                }
                .frame(height: 150)
                .chartYAxis { AxisMarks(position: .trailing) }
            }
        }
    }

    private func chartPoints() -> [HubChartPoint] {
        range.series(summaries, type: type, asOf: .now, calendar: .current)
    }
}

enum HubChartRange: CaseIterable {
    case twelveWeeks
    case year
    case all

    var label: String {
        switch self {
        case .twelveWeeks:
            String(localized: "12 wk")
        case .year:
            String(localized: "1 yr")
        case .all:
            String(localized: "All")
        }
    }

    var calendarUnit: Calendar.Component {
        self == .twelveWeeks ? .weekOfYear : .month
    }

    /// The points this range draws.
    ///
    /// Lifted out of the view because the bucket size and the window size have
    /// to agree and once did not: "12 wk" asked `weeklySeries` for weekly
    /// buckets and then filtered them with a *daily* cutoff, so the chart drew a
    /// single bar. The pairing is the whole content of this method, and it is
    /// only checkable where a test can call it.
    func series(_ summaries: [ActivityWorkoutSummary],
                type: ActivityType,
                asOf: Date,
                calendar: Calendar) -> [HubChartPoint] {
        switch self {
        case .twelveWeeks:
            return InsightsMath.weeklySeries(summaries, type: type, weeks: 12,
                                             endingAt: asOf, calendar: calendar)
                .map { HubChartPoint(date: $0.weekStart,
                                     distanceMeters: $0.distanceMeters,
                                     avgPaceSecPerKm: $0.avgPaceSecPerKm) }
        case .year:
            return Self.monthly(summaries, type: type, months: 12,
                                asOf: asOf, calendar: calendar)
        case .all:
            return Self.monthly(summaries, type: type,
                                months: HubMath.monthsSpanningAll(summaries, endingAt: asOf,
                                                                  calendar: calendar),
                                asOf: asOf, calendar: calendar)
        }
    }

    private static func monthly(_ summaries: [ActivityWorkoutSummary],
                                type: ActivityType, months: Int,
                                asOf: Date, calendar: Calendar) -> [HubChartPoint] {
        HubMath.monthlySeries(summaries, type: type, months: months,
                              endingAt: asOf, calendar: calendar)
            .map { HubChartPoint(date: $0.monthStart,
                                 distanceMeters: $0.distanceMeters,
                                 avgPaceSecPerKm: $0.avgPaceSecPerKm) }
    }
}

/// Internal, not private: the range's own `series(...)` returns these, and a
/// test has to be able to read what it produced.
struct HubChartPoint: Identifiable, Equatable {
    let date: Date
    let distanceMeters: Double
    let avgPaceSecPerKm: Double?

    var id: Date { date }
}
