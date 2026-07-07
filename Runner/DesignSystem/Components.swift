import SwiftUI

struct GlowNumber: View {
    let value: Int
    let unitLabel: String
    var prefix = ""
    var size: Double = 64
    var unitSize: Double = 16
    var numberColor: Color = .white

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(prefix)\(value)")
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .foregroundStyle(numberColor)
                .contentTransition(.numericText())
                .modifier(GlowShadow(color: .rLime))
            Text(unitLabel)
                .font(.system(size: unitSize, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rLime)
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var accent: Color = .white

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 4) {
                MicroLabel(text: label)
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

struct SplitsCard: View {
    let splitSeconds: [Double]
    var title: String?

    var body: some View {
        SurfaceCard {
            VStack(spacing: 6) {
                if let title {
                    MicroLabel(text: title)
                }
                ForEach(Array(splitSeconds.enumerated()), id: \.offset) { index, seconds in
                    HStack {
                        Text(String(localized: "Km \(index + 1)"))
                            .font(.system(size: 13))
                            .foregroundStyle(Color.rTextSecondary)
                        Spacer()
                        Text(Format.duration(seconds))
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }
}

struct GoalBar: View {
    let points: Int
    let goal: Int

    private var fraction: Double {
        guard goal > 0 else { return 0 }
        return min(Double(points) / Double(goal), 1.0)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0x1B1E27))
                Capsule()
                    .fill(LinearGradient(colors: [.rLime, .rTeal],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geo.size.width * fraction, fraction > 0 ? 8 : 0))
                    .shadow(color: Color.rLime.opacity(0.6), radius: 6)
            }
        }
        .frame(height: 6)
        .animation(.spring(duration: 0.5), value: points)
    }
}

struct SurfaceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.rSurface)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.rBorder, lineWidth: 1))
            )
    }
}

struct MicroLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(2)
            .textCase(.uppercase)
            .foregroundStyle(Color.rTextSecondary)
    }
}
