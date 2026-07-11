import Testing
import Foundation
@testable import Runner

struct WeekMathTests {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(timeZone: cal.timeZone,
                                      year: year, month: month, day: day, hour: hour))!
    }

    @Test func midWeekMapsBackToMonday() {
        // 2026-07-10 is a Friday; its week starts Monday 2026-07-06.
        #expect(WeekMath.mondayStart(for: date(2026, 7, 10), calendar: cal)
                == cal.startOfDay(for: date(2026, 7, 6)))
    }

    @Test func mondayAndSundayBoundaries() {
        // A Monday maps to itself (start of day).
        #expect(WeekMath.mondayStart(for: date(2026, 7, 6, hour: 0), calendar: cal)
                == cal.startOfDay(for: date(2026, 7, 6)))
        // Sunday 2026-07-12 still belongs to the week of Monday 2026-07-06.
        #expect(WeekMath.mondayStart(for: date(2026, 7, 12, hour: 23), calendar: cal)
                == cal.startOfDay(for: date(2026, 7, 6)))
    }

    @Test func dstTransitionWeek() {
        // DST starts 2026-03-08 (Sunday) in Toronto; Thu 2026-03-12 maps to Mon 2026-03-09.
        #expect(WeekMath.mondayStart(for: date(2026, 3, 12), calendar: cal)
                == cal.startOfDay(for: date(2026, 3, 9)))
    }
}
