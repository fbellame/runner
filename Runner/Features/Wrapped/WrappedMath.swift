import Foundation

struct WrappedMonth: Hashable, Comparable, Sendable {
    let year: Int
    let month: Int

    static func < (lhs: WrappedMonth, rhs: WrappedMonth) -> Bool {
        lhs.year == rhs.year ? lhs.month < rhs.month : lhs.year < rhs.year
    }

    func startDate(calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(timeZone: calendar.timeZone,
                                           year: year,
                                           month: month,
                                           day: 1))!
    }
}

struct MonthWrapped: Identifiable, Equatable, Sendable {
    let month: WrappedMonth
    let cards: [WrappedCard]

    var id: WrappedMonth { month }
}

enum WrappedCard: Equatable, Sendable {
    case intro(WrappedMonth)
    case totals(WrappedTotals)
    case highlights(longestWorkouts: [WrappedLongestWorkout], personalRecords: [WrappedPersonalRecord])
    case badges([Badge])
    case consistency(WrappedConsistency)
    case impact(WrappedImpact)
    case finale(WrappedFinale)
}

struct WrappedTotals: Equatable, Sendable {
    let distanceMeters: Double
    let workoutCount: Int
    let movingSeconds: Double
    let distanceDeltaFraction: Double?
}

struct WrappedLongestWorkout: Equatable, Sendable {
    let type: ActivityType
    let distanceMeters: Double
    let distanceEstimated: Bool
    let date: Date
}

struct WrappedPersonalRecord: Identifiable, Equatable, Sendable {
    let type: ActivityType
    let record: PersonalRecord

    var id: String { "\(type.rawValue)-\(record.kind)" }
}

struct WrappedHeatDay: Identifiable, Equatable, Sendable {
    let date: Date
    let workoutCount: Int

    var id: Date { date }
}

struct WrappedConsistency: Equatable, Sendable {
    let activeDays: Int
    let bestStreak: Int
    let heatStrip: [WrappedHeatDay]
}

struct WrappedImpact: Equatable, Sendable {
    let calories: Double
    let co2SavedGrams: Double
    let carKilometers: Double
}

struct WrappedFinale: Equatable, Sendable {
    let distanceMeters: Double
    let workoutCount: Int
    let activeDays: Int
    let co2SavedGrams: Double
}

enum WrappedMath {
    static func availableMonths(_ summaries: [ActivityWorkoutSummary],
                                asOf: Date,
                                calendar: Calendar) -> [WrappedMonth] {
        let currentMonth = month(containing: asOf, calendar: calendar)
        return Set(summaries.map { month(containing: $0.date, calendar: calendar) })
            .filter { $0 < currentMonth }
            .sorted(by: >)
    }

    static func monthWrapped(_ summaries: [ActivityWorkoutSummary],
                             month: WrappedMonth,
                             calendar: Calendar) -> MonthWrapped? {
        let bounds = monthBounds(for: month, calendar: calendar)
        let inMonth = summaries.filter { $0.date >= bounds.start && $0.date < bounds.end }
        guard !inMonth.isEmpty else { return nil }

        let previousMonth = calendar.date(byAdding: .month, value: -1, to: bounds.start)!
        let previousBounds = (start: previousMonth, end: bounds.start)
        let previous = summaries.filter { $0.date >= previousBounds.start && $0.date < previousBounds.end }

        let distanceMeters = inMonth.reduce(0.0) { $0 + $1.distanceMeters }
        let previousDistanceMeters = previous.reduce(0.0) { $0 + $1.distanceMeters }
        let totals = WrappedTotals(
            distanceMeters: distanceMeters,
            workoutCount: inMonth.count,
            movingSeconds: inMonth.reduce(0.0) { $0 + $1.movingSeconds },
            distanceDeltaFraction: previous.isEmpty || previousDistanceMeters == 0
                ? nil
                : (distanceMeters - previousDistanceMeters) / previousDistanceMeters
        )

        let highlights = WrappedCard.highlights(
            longestWorkouts: longestWorkouts(in: inMonth),
            personalRecords: personalRecords(before: bounds.start,
                                             through: bounds.end,
                                             summaries: summaries)
        )
        let badges = badges(before: bounds.start, through: bounds.end, summaries: summaries)
        let consistency = consistency(in: inMonth, bounds: bounds, calendar: calendar)
        let impact = impact(in: inMonth)
        let finale = WrappedFinale(distanceMeters: distanceMeters,
                                   workoutCount: inMonth.count,
                                   activeDays: consistency.activeDays,
                                   co2SavedGrams: impact?.co2SavedGrams ?? 0)

        var cards: [WrappedCard] = [.intro(month), .totals(totals), highlights]
        if !badges.isEmpty { cards.append(.badges(badges)) }
        cards.append(.consistency(consistency))
        if let impact { cards.append(.impact(impact)) }
        cards.append(.finale(finale))
        return MonthWrapped(month: month, cards: cards)
    }

    private static func month(containing date: Date, calendar: Calendar) -> WrappedMonth {
        let components = calendar.dateComponents([.year, .month], from: date)
        return WrappedMonth(year: components.year!, month: components.month!)
    }

    private static func monthBounds(for month: WrappedMonth, calendar: Calendar) -> (start: Date, end: Date) {
        let start = month.startDate(calendar: calendar)
        return (start, calendar.date(byAdding: .month, value: 1, to: start)!)
    }

    private static func longestWorkouts(in summaries: [ActivityWorkoutSummary]) -> [WrappedLongestWorkout] {
        ActivityType.allCases.compactMap { type in
            guard let longest = summaries.filter({ $0.type == type }).max(by: { lhs, rhs in
                lhs.distanceMeters == rhs.distanceMeters ? lhs.date > rhs.date : lhs.distanceMeters < rhs.distanceMeters
            }) else {
                return nil
            }
            return WrappedLongestWorkout(type: type,
                                        distanceMeters: longest.distanceMeters,
                                        distanceEstimated: longest.distanceEstimated,
                                        date: longest.date)
        }
    }

    private static func personalRecords(before start: Date,
                                        through end: Date,
                                        summaries: [ActivityWorkoutSummary]) -> [WrappedPersonalRecord] {
        let before = summaries.filter { $0.date < start }
        let through = summaries.filter { $0.date < end }

        return ActivityType.allCases.flatMap { type in
            let prior = ActivityStats.typeRecords(before, type: type)
            return ActivityStats.typeRecords(through, type: type).compactMap { record -> WrappedPersonalRecord? in
                guard !prior.contains(where: { $0.kind == record.kind && $0 == record }) else { return nil }
                return WrappedPersonalRecord(type: type, record: record)
            }
        }
    }

    private static func badges(before start: Date,
                               through end: Date,
                               summaries: [ActivityWorkoutSummary]) -> [Badge] {
        let priorIDs = Set(TrophyMath.allBadges(summaries.filter { $0.date < start })
            .filter(\.earned)
            .map(\.id))
        return TrophyMath.allBadges(summaries.filter { $0.date < end })
            .filter { $0.earned && !priorIDs.contains($0.id) }
    }

    private static func consistency(in summaries: [ActivityWorkoutSummary],
                                    bounds: (start: Date, end: Date),
                                    calendar: Calendar) -> WrappedConsistency {
        let activeDates = Set(summaries.map { calendar.startOfDay(for: $0.date) })
        var heatStrip: [WrappedHeatDay] = []
        var cursor = bounds.start
        while cursor < bounds.end {
            let day = calendar.startOfDay(for: cursor)
            heatStrip.append(WrappedHeatDay(date: day,
                                            workoutCount: summaries.filter {
                                                calendar.isDate($0.date, inSameDayAs: day)
                                            }.count))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }

        var bestStreak = 0
        var currentStreak = 0
        for day in heatStrip {
            if activeDates.contains(day.date) {
                currentStreak += 1
                bestStreak = max(bestStreak, currentStreak)
            } else {
                currentStreak = 0
            }
        }
        return WrappedConsistency(activeDays: activeDates.count,
                                  bestStreak: bestStreak,
                                  heatStrip: heatStrip)
    }

    private static func impact(in summaries: [ActivityWorkoutSummary]) -> WrappedImpact? {
        let calories = summaries.reduce(0.0) { $0 + $1.calories }
        let co2SavedGrams = summaries.reduce(0.0) { $0 + $1.co2SavedGrams }
        guard calories > 0 || co2SavedGrams > 0 else { return nil }
        return WrappedImpact(calories: calories,
                             co2SavedGrams: co2SavedGrams,
                             carKilometers: co2SavedGrams / CO2Estimator.carGramsPerKm)
    }
}
