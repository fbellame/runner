import SwiftUI

/// The per-activity flavor block: run best efforts (this year vs all-time),
/// Bixi green impact, walk volume.
struct ActivitySpecificBlock: View {
    let type: ActivityType
    let summaries: [ActivityWorkoutSummary]

    var body: some View {
        switch type {
        case .run:
            runBestEfforts
        case .bike:
            bikeImpact
        case .walk:
            walkVolume
        }
    }

    // MARK: - Run

    private var runBestEfforts: some View {
        let year = Calendar.current.component(.year, from: .now)
        let allTime = ActivityStats.typeRecords(summaries, type: .run)
        let thisYear = ActivityStats.typeRecords(
            summaries.filter { Calendar.current.component(.year, from: $0.date) == year },
            type: .run)
        let yearByKind = Dictionary(uniqueKeysWithValues: thisYear.map { ($0.kind, $0) })

        return VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: String(format: String(localized: "%d vs all-time"), year))
            if allTime.isEmpty {
                notEnoughData
            } else {
                SurfaceCard {
                    VStack(spacing: 10) {
                        ForEach(allTime, id: \.kind) { record in
                            bestEffortRow(allTime: record, thisYear: yearByKind[record.kind])
                        }
                    }
                }
            }
        }
    }

    private func bestEffortRow(allTime: PersonalRecord,
                               thisYear: PersonalRecord?) -> some View {
        let beatenThisYear = thisYear.map { $0.value == allTime.value } ?? false

        return HStack {
            Text(RecordRow.emoji(allTime.kind))
            Text(RecordRow.title(allTime.kind))
                .font(.system(size: 14))
                .foregroundStyle(.white)
            if beatenThisYear {
                Text(String(localized: "set this year 🔥"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.rLime)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(thisYear.map { RecordRow.value($0) } ?? "—")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(type.accent)
                Text(String(format: String(localized: "all-time %@"), RecordRow.value(allTime)))
                    .font(.caption2)
                    .foregroundStyle(Color.rTextSecondary)
            }
        }
    }

    // MARK: - Bixi

    private var bikeImpact: some View {
        let review = HubMath.yearInReview(summaries, type: .bike,
                                          asOf: .now, calendar: .current)
        let stats = ActivityStats.typeStats(summaries, type: .bike, calendar: .current)
        let lifetimeCo2 = summaries.filter { $0.type == .bike }
            .reduce(0.0) { $0 + $1.co2SavedGrams }
        let carKm = lifetimeCo2 / CO2Estimator.carGramsPerKm

        return VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: String(localized: "Green impact"))
            if stats.sessions == 0 {
                notEnoughData
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    StatTile(label: String(format: String(localized: "Rides in %d"), review.year),
                             value: "\(review.sessions.current)",
                             accent: type.accent)
                    StatTile(label: String(localized: "Rides lifetime"),
                             value: "\(stats.sessions)",
                             accent: .white)
                    StatTile(label: String(format: String(localized: "CO₂ avoided in %d"), review.year),
                             value: Format.co2(grams: review.co2SavedGrams.current),
                             accent: .rLime)
                    StatTile(label: String(localized: "CO₂ avoided lifetime"),
                             value: Format.co2(grams: lifetimeCo2),
                             accent: .rLime)
                }
                if carKm >= 1 {
                    SurfaceCard {
                        Text(String(format: String(localized: "≈ %@ not driven by car 🌱"),
                                    Format.km(carKm * 1000)))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.rLime)
                    }
                }
            }
        }
    }

    // MARK: - Walk

    private var walkVolume: some View {
        let review = HubMath.yearInReview(summaries, type: .walk,
                                          asOf: .now, calendar: .current)
        let stats = ActivityStats.typeStats(summaries, type: .walk, calendar: .current)

        return VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: String(localized: "Walking volume"))
            if stats.sessions == 0 {
                notEnoughData
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    StatTile(label: String(format: String(localized: "Hours in %d"), review.year),
                             value: hours(review.movingSeconds.current),
                             accent: type.accent)
                    StatTile(label: String(localized: "Hours lifetime"),
                             value: hours(stats.totalMovingSeconds),
                             accent: .white)
                    StatTile(label: String(format: String(localized: "Distance in %d"), review.year),
                             value: Format.km(review.distanceMeters.current),
                             accent: .rLime)
                    StatTile(label: String(localized: "Distance lifetime"),
                             value: Format.km(stats.totalDistanceMeters),
                             accent: .rTeal)
                }
            }
        }
    }

    private var notEnoughData: some View {
        SurfaceCard {
            Text(String(localized: "Not enough data yet — keep at it!"))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.rTextSecondary)
        }
    }

    private func hours(_ seconds: Double) -> String {
        String(format: String(localized: "%@ h"),
               (seconds / 3600).formatted(.number.precision(.fractionLength(1))))
    }
}
