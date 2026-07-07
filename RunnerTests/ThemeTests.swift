import Testing
import SwiftUI
@testable import Runner

struct ThemeTests {
    @Test func hexColorResolvesComponents() {
        let c = UIColor(Color(hex: 0xC8FF00))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(abs(r - 200.0/255.0) < 0.01)
        #expect(abs(g - 1.0) < 0.01)
        #expect(abs(b - 0.0) < 0.01)
        #expect(a == 1.0)
    }

    @Test func activityAccents() {
        #expect(ActivityType.run.emoji == "🏃")
        #expect(ActivityType.walk.emoji == "🚶")
        #expect(ActivityType.bike.emoji == "🚴")
        #expect(ActivityType.allCases.count == 3)
    }
}
