import SwiftUI
import Charts

/// YTD totals vs the same date range last year, plus a 12-month chart of the
/// current calendar year with last year's months as ghost bars behind.
struct YearInReviewBlock: View {
    let type: ActivityType
    let summaries: [ActivityWorkoutSummary]

    var body: some View {
        let review = HubMath.yearInReview(summaries, type: type,
                                          asOf: .now, calendar: .current)
        let months = HubMath.yearMonthlyComparison(summaries, type: type,
                                                   year: review.year, calendar: .current)

        VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: String(localized: "Year in review"))
            if review.sessions.current == 0 && review.isFirstTrackedYear {
                SurfaceCard {
                    Text(String(localized: "Not enough data yet — keep at it!"))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.rTextSecondary)
                }
            } else {
                headlineCard(review)
                ghostChart(months, year: review.year)
            }
        }
    }

    private func headlineCard(_ review: YearInReview) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.km(review.distanceMeters.current))
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(type.accent)
                    Text(String(format: String(localized: "in %d"), review.year))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rTextSecondary)
                }
                if review.isFirstTrackedYear {
                    Text(String(localized: "Your first tracked year 🎉"))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.rTextSecondary)
                } else {
                    Text(comparisonSentence(review))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.rTextSecondary)
                    Text(sessionsSentence(review))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.rTextSecondary)
                }
            }
        }
    }

    private func comparisonSentence(_ review: YearInReview) -> String {
        var sentence = String(format: String(localized: "vs %@ by this time in %d"),
                              Format.km(review.distanceMeters.previous),
                              review.year - 1)
        if let delta = review.distanceDeltaFraction {
            let arrow = delta >= 0 ? "▲" : "▼"
            let percent = abs(delta).formatted(.percent.precision(.fractionLength(0)))
            sentence += " · \(arrow) \(percent)"
        }
        return sentence
    }

    private func sessionsSentence(_ review: YearInReview) -> String {
        String(format: String(localized: "%d sessions (vs %d) · %@ (vs %@)"),
               review.sessions.current,
               review.sessions.previous,
               Format.duration(review.movingSeconds.current),
               Format.duration(review.movingSeconds.previous))
    }

    private func ghostChart(_ points: [YearMonthPoint], year: Int) -> some View {
        let calendar = Calendar.current
        let previousLabel = String(year - 1)
        let currentLabel = String(year)

        return Chart {
            ForEach(points) { point in
                let monthDate = calendar.date(from: DateComponents(year: year,
                                                                   month: point.monthIndex,
                                                                   day: 1))!
                BarMark(x: .value(String(localized: "Month"), monthDate, unit: .month),
                        y: .value(String(localized: "Distance"), point.previousMeters / 1000.0))
                    .foregroundStyle(by: .value(String(localized: "Year"), previousLabel))
                    .position(by: .value(String(localized: "Year"), previousLabel))
                    .cornerRadius(3)
                BarMark(x: .value(String(localized: "Month"), monthDate, unit: .month),
                        y: .value(String(localized: "Distance"), point.currentMeters / 1000.0))
                    .foregroundStyle(by: .value(String(localized: "Year"), currentLabel))
                    .position(by: .value(String(localized: "Year"), currentLabel))
                    .cornerRadius(3)
            }
        }
        .chartForegroundStyleScale([previousLabel: type.accent.opacity(0.25),
                                    currentLabel: type.accent])
        .frame(height: 150)
        .chartYAxis { AxisMarks(position: .trailing) }
    }
}
