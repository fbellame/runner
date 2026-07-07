import Foundation
import SwiftData

@MainActor
final class DataStore {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: DayLedger.self, WorkoutRec.self, configurations: config)
    }

    // MARK: Ledger

    func upsert(_ days: [LedgerDay]) throws {
        guard !days.isEmpty else { return }
        let cal = Calendar.current
        // One ranged fetch for the whole batch instead of a predicate fetch per day.
        let keys = days.map { cal.startOfDay(for: $0.date) }
        var byDay = Dictionary(uniqueKeysWithValues:
            try ledgers(from: keys.min()!, through: keys.max()!).map { ($0.date, $0) })
        for day in days {
            let key = cal.startOfDay(for: day.date)
            if let existing = byDay[key] {
                existing.apply(day)
            } else {
                // Normalize at write time so the unique key is always startOfDay,
                // regardless of caller discipline.
                let inserted = DayLedger(date: key,
                                         steps: day.steps,
                                         stepPoints: day.breakdown.stepPoints,
                                         workoutPoints: day.breakdown.workoutPoints,
                                         multiplier: day.breakdown.multiplier,
                                         totalPoints: day.breakdown.total,
                                         goalAtThatTime: day.goal,
                                         isGold: day.isGold,
                                         streakAfter: day.streakAfter)
                context.insert(inserted)
                byDay[key] = inserted // dedupe repeated keys within the same batch
            }
        }
        try context.save()
    }

    func ledger(on date: Date) throws -> DayLedger? {
        let day = Calendar.current.startOfDay(for: date)
        var descriptor = FetchDescriptor<DayLedger>(predicate: #Predicate { $0.date == day })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func ledgers(from: Date, through: Date) throws -> [DayLedger] {
        let lo = Calendar.current.startOfDay(for: from)
        let hi = Calendar.current.startOfDay(for: through)
        let descriptor = FetchDescriptor<DayLedger>(
            predicate: #Predicate { $0.date >= lo && $0.date <= hi },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    func latestLedger(before date: Date) throws -> DayLedger? {
        let day = Calendar.current.startOfDay(for: date)
        var descriptor = FetchDescriptor<DayLedger>(
            predicate: #Predicate { $0.date < day },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: Workouts

    @discardableResult
    func upsertWorkout(id: UUID, type: ActivityType, start: Date, end: Date,
                       movingSeconds: Double, distanceMeters: Double, points: Int,
                       routeData: Data?, splitSeconds: [Double],
                       source: String, hkSynced: Bool) throws -> WorkoutRec {
        var descriptor = FetchDescriptor<WorkoutRec>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let rec: WorkoutRec
        if let existing = try context.fetch(descriptor).first {
            existing.typeRaw = type.rawValue
            existing.start = start
            existing.end = end
            existing.movingSeconds = movingSeconds
            existing.distanceMeters = distanceMeters
            existing.points = points
            existing.routeData = routeData ?? existing.routeData
            existing.splitSeconds = splitSeconds
            existing.source = source
            existing.hkSynced = hkSynced
            rec = existing
        } else {
            rec = WorkoutRec(id: id, typeRaw: type.rawValue, start: start, end: end,
                             movingSeconds: movingSeconds, distanceMeters: distanceMeters,
                             points: points, routeData: routeData, splitSeconds: splitSeconds,
                             source: source, hkSynced: hkSynced)
            context.insert(rec)
        }
        try context.save()
        return rec
    }

    func workouts(onDay date: Date) throws -> [WorkoutRec] {
        let cal = Calendar.current
        let lo = cal.startOfDay(for: date)
        let hi = cal.date(byAdding: .day, value: 1, to: lo)!
        let descriptor = FetchDescriptor<WorkoutRec>(
            predicate: #Predicate { $0.start >= lo && $0.start < hi },
            sortBy: [SortDescriptor(\.start, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    func allWorkouts() throws -> [WorkoutRec] {
        try context.fetch(FetchDescriptor<WorkoutRec>(sortBy: [SortDescriptor(\.start, order: .reverse)]))
    }

    func pendingSync() throws -> [WorkoutRec] {
        try context.fetch(FetchDescriptor<WorkoutRec>(
            predicate: #Predicate { $0.source == "runner" && $0.hkSynced == false }
        ))
    }

    // MARK: Goals

    func goalProvider(currentGoal: Int, from: Date? = nil) -> (Date) -> Int {
        // When a window start is given, fetch only that range instead of every ledger.
        let rows: [DayLedger]
        if let from {
            rows = (try? ledgers(from: from, through: .now)) ?? []
        } else {
            rows = (try? context.fetch(FetchDescriptor<DayLedger>())) ?? []
        }
        let stored = Dictionary(uniqueKeysWithValues: rows.map { ($0.date, $0.goalAtThatTime) })
        let todayStart = Calendar.current.startOfDay(for: .now)
        return { date in
            let day = Calendar.current.startOfDay(for: date)
            guard day < todayStart else { return currentGoal } // today forward: live goal
            return stored[day] ?? currentGoal
        }
    }
}
