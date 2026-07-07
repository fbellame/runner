import SwiftUI

struct SlideToFinish: View {
    let onFinish: () -> Void
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.width - 62
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.rSurface)
                    .overlay(Capsule().stroke(Color.rBorder, lineWidth: 1))
                Text(String(localized: "Slide to finish"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.rTextSecondary)
                    .frame(maxWidth: .infinity)
                    .opacity(1.0 - Double(offset / max(travel, 1)) * 1.6)
                Circle()
                    .fill(Color.rLime)
                    .frame(width: 50, height: 50)
                    .overlay(
                        Image(systemName: "flag.checkered")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color.rBackground)
                    )
                    .offset(x: offset + 6)
                    .gesture(
                        DragGesture()
                            .onChanged { offset = min(max(0, $0.translation.width), travel) }
                            .onEnded { _ in
                                if offset > travel * 0.85 {
                                    onFinish()
                                } else {
                                    withAnimation(.spring(duration: 0.3)) {
                                        offset = 0
                                    }
                                }
                            }
                    )
            }
        }
        .frame(height: 62)
    }
}
