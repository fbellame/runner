import SwiftUI
import Charts

struct WorkoutDetailView: View {
    let workout: WorkoutRec

    private var route: [RoutePoint] {
        workout.routeData.map { [RoutePoint].decode($0) } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if route.count >= 2 {
                    RouteMapView(points: route, interactive: true)
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.rBorder, lineWidth: 1))
                } else {
                    SurfaceCard {
                        Label(String(localized: "No route for this workout (imported from Health)"),
                              systemImage: "map")
                            .font(.caption)
                            .foregroundStyle(Color.rTextSecondary)
                    }
                }

                HStack(spacing: 10) {
                    StatTile(label: String(localized: "Points"), value: "+\(workout.points)", accent: .rLime)
                    StatTile(label: String(localized: "Distance"),
                             value: Format.km(workout.distanceMeters,
                                              estimated: workout.distanceEstimated))
                    StatTile(label: String(localized: "Time"),
                             value: workout.movingSeconds > 0 ? Format.duration(workout.movingSeconds) : "—")
                }

                if workout.calories > 0 || workout.co2SavedGrams > 0 {
                    HStack(spacing: 10) {
                        if workout.calories > 0 {
                            StatTile(label: String(localized: "Calories"),
                                     value: Format.kcal(workout.calories,
                                                        estimated: !workout.caloriesFromHealth),
                                     accent: .rOrange)
                        }
                        if workout.co2SavedGrams > 0 {
                            StatTile(label: String(localized: "CO₂ saved"),
                                     value: Format.co2(grams: workout.co2SavedGrams),
                                     accent: .rLime)
                        }
                    }
                }

                if !workout.splitSeconds.isEmpty {
                    SplitAnalysisCard(splitSeconds: workout.splitSeconds,
                                      activityType: workout.type)
                }
                Spacer(minLength: 90)
            }
            .padding(18)
        }
        .background(Color.rBackground)
        .navigationTitle("\(workout.type.emoji) \(workout.start.formatted(date: .abbreviated, time: .shortened))")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SplitAnalysisCard: View {
    let splitSeconds: [Double]
    let activityType: ActivityType

    private var analysis: SplitAnalysis {
        SplitStats.analyze(splitSeconds)
    }

    var body: some View {
        let analysis = analysis
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                MicroLabel(text: String(localized: "Splits"))

                if !analysis.splits.isEmpty {
                    highlights(analysis)
                }

                if analysis.splits.count >= 2 {
                    paceChart(analysis)
                }

                splitList(analysis.splits)
            }
        }
    }

    private func highlights(_ analysis: SplitAnalysis) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let fastestIndex = analysis.fastestKmIndex {
                SplitHighlight(label: String(localized: "Fastest km"),
                               value: splitSummary(analysis.splits[fastestIndex]),
                               accent: activityType.accent)
            }
            if let slowestIndex = analysis.slowestKmIndex {
                SplitHighlight(label: String(localized: "Slowest km"),
                               value: splitSummary(analysis.splits[slowestIndex]),
                               accent: .rOrange)
            }
            if let verdict = negativeSplitVerdict(analysis.negativeSplit) {
                SplitVerdictHighlight(title: verdict.title,
                                      detail: verdict.detail,
                                      accent: verdict.accent,
                                      checked: verdict.checked)
            }
        }
    }

    private func paceChart(_ analysis: SplitAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: String(localized: "Pace per km (lower = faster)"))
            Chart {
                ForEach(analysis.splits) { split in
                    BarMark(x: .value(String(localized: "Km"), split.km),
                            y: .value(String(localized: "Pace"), split.seconds))
                        .foregroundStyle(barColor(for: split))
                        .cornerRadius(3)
                }
                if let average = analysis.averageSecPerKm {
                    RuleMark(y: .value(String(localized: "Avg"), average))
                        .foregroundStyle(Color.rTextSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text(String(localized: "Avg"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.rTextSecondary)
                        }
                }
            }
            .frame(height: 150)
            .chartYAxis { AxisMarks(position: .trailing) }
        }
    }

    private func splitList(_ splits: [SplitDetail]) -> some View {
        VStack(spacing: 6) {
            ForEach(splits) { split in
                HStack(spacing: 8) {
                    if split.isFastest {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(activityType.accent)
                    }
                    Text(kmLabel(split.km))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.rTextSecondary)
                    Spacer()
                    Text(Format.duration(split.seconds))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func barColor(for split: SplitDetail) -> Color {
        if split.isFastest {
            return activityType.accent
        }
        if split.isSlowest {
            return .rOrange
        }
        return Color.rTextSecondary.opacity(0.45)
    }

    private func splitSummary(_ split: SplitDetail) -> String {
        String.localizedStringWithFormat(String(localized: "Km %lld · %@"),
                                         Int64(split.km),
                                         Format.duration(split.seconds))
    }

    private func kmLabel(_ km: Int) -> String {
        String.localizedStringWithFormat(String(localized: "Km %lld"), Int64(km))
    }

    private func negativeSplitVerdict(_ split: NegativeSplit)
    -> (title: String, detail: String?, accent: Color, checked: Bool)? {
        switch split {
        case .negative(let delta):
            return (String(localized: "Negative split"),
                    String(format: String(localized: "Second half %@ faster"),
                           Format.duration(delta)),
                    .rLime,
                    true)
        case .positive(let delta):
            return (String(localized: "Positive split"),
                    String(format: String(localized: "Second half %@ slower"),
                           Format.duration(delta)),
                    .rOrange,
                    false)
        case .even:
            return (String(localized: "Even pace"),
                    nil,
                    .rTextSecondary,
                    false)
        case .notApplicable:
            return nil
        }
    }
}

private struct SplitHighlight: View {
    let label: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MicroLabel(text: label)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SplitVerdictHighlight: View {
    let title: String
    let detail: String?
    let accent: Color
    let checked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if checked {
                    Image(systemName: "checkmark")
                }
                Text(title)
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(accent)
            .lineLimit(2)
            .minimumScaleFactor(0.75)

            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.rTextSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
