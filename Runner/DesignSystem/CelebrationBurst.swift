import SwiftUI

struct CelebrationBurst: View {
    @State private var scale: CGFloat = 0.4
    @State private var opacity: Double = 0.9

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color.rLime.opacity(0.5), .clear],
                                 center: .center,
                                 startRadius: 10,
                                 endRadius: 240))
            .scaleEffect(scale)
            .opacity(opacity)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 1.4)) {
                    scale = 2.4
                    opacity = 0
                }
                Haptics.goalReached()
            }
    }
}
