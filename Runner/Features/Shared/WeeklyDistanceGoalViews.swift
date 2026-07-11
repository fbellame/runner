import SwiftUI

enum DistanceGoalFormat {
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func progress(_ progress: ActivityDistanceGoalProgress) -> String {
        String(format: String(localized: "%@/%@ km"),
               number(progress.distanceMeters / 1_000),
               number(progress.goalKilometers))
    }
}

struct WeeklyDistanceGoalRing: View {
    let fraction: Double
    let accent: Color
    var size: Double = 66
    var lineWidth: Double = 7
    var centerText: String?

    var body: some View {
        ZStack {
            Circle().stroke(Color.rBorder, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: accent.opacity(0.35), radius: 5)
            if let centerText {
                Text(centerText)
                    .font(.system(size: size * 0.2, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.5), value: fraction)
    }
}

struct WeeklyDistanceGoalMiniRing: View {
    let progress: ActivityDistanceGoalProgress

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                WeeklyDistanceGoalRing(fraction: progress.fraction,
                                       accent: progress.type.accent,
                                       size: 50,
                                       lineWidth: 5)
                Text(progress.type.emoji)
                    .font(.system(size: 19))
            }
            Text(DistanceGoalFormat.progress(progress))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(progress.type.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progress.type.localizedName), \(DistanceGoalFormat.progress(progress))")
    }
}
