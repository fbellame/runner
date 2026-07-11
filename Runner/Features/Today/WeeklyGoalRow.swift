import SwiftUI

struct WeeklyGoalRow: View {
    let status: WeeklyGoalStatus

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(Array(status.dots.enumerated()), id: \.offset) { _, dot in
                    dotView(dot)
                }
            }
            Text(String(format: String(localized: "%d of %d this week"),
                        status.goldDays, status.target))
                .font(.caption)
                .foregroundStyle(status.isMet ? Color.rLime : Color.rTextSecondary)
            Spacer()
            if status.streak >= 2 {
                Text(String(format: String(localized: "%lld-week streak"), Int64(status.streak)))
                    .font(.caption.bold())
                    .foregroundStyle(Color.rLime)
            }
        }
    }

    @ViewBuilder
    private func dotView(_ dot: GoalDotState) -> some View {
        switch dot {
        case .gold:
            Circle().fill(Color.rLime).frame(width: 8, height: 8)
        case .missed:
            Circle().stroke(Color.rTextSecondary, lineWidth: 1).frame(width: 8, height: 8)
        case .future:
            Circle().fill(Color.rTextSecondary.opacity(0.25)).frame(width: 8, height: 8)
        }
    }
}
