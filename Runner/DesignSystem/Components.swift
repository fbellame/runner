import SwiftUI

struct GlowNumber: View {
    let value: Int
    let unitLabel: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(value)")
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .modifier(GlowShadow(color: .rLime))
            Text(unitLabel)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rLime)
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
