import Testing
import Foundation
@testable import Runner

struct HistoryMathTests {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }

    private let wednesday = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2026, month: 7, day: 1))!

    private func d(_ offset: Int) -> Date {
        cal.date(byAdding: .day, value: offset, to: wednesday)!
    }

    @Test func heatmapShapeAndAlignment() {
        let days = [DaySnapshot(date: d(0), points: 120, isGold: true)]
        let weeks = HistoryMath.heatmapWeeks(days: days, today: d(0), weekCount: 2, calendar: cal)

        #expect(weeks.count == 2)
        #expect(weeks.allSatisfy { $0.count == 7 })
        #expect(weeks[1][2]?.points == 120)
        #expect(weeks[1][3] == nil)
        #expect(weeks[1][6] == nil)
        #expect(weeks[0][0]?.points == 0)
    }

    @Test func intensityCurve() {
        #expect(HistoryMath.intensity(points: 0, goal: 100) == 0)
        #expect(abs(HistoryMath.intensity(points: 50, goal: 100) - 0.625) < 0.0001)
        #expect(HistoryMath.intensity(points: 100, goal: 100) == 1.0)
        #expect(HistoryMath.intensity(points: 400, goal: 100) == 1.0)
        #expect(HistoryMath.intensity(points: 10, goal: 0) == 1.0)
    }

    @Test func dailySeriesZeroFills() {
        let days = [DaySnapshot(date: d(-1), points: 80, isGold: false)]
        let series = HistoryMath.dailySeries(days: days, lastN: 7, endingAt: d(0), calendar: cal)

        #expect(series.count == 7)
        #expect(series.last?.points == 0)
        #expect(series[5].points == 80)
        #expect(series.first?.date == d(-6))
    }
}
