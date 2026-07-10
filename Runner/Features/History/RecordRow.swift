import SwiftUI

/// One personal-record line, shared by ActivityDetailView and the hub records block.
struct RecordRow: View {
    let record: PersonalRecord
    let accent: Color
    var showsChevron = false

    var body: some View {
        HStack {
            Text(Self.emoji(record.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(record.kind))
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                if let date = record.date {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(Color.rTextSecondary)
                }
            }
            Spacer()
            Text(Self.value(record))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.rTextSecondary)
            }
        }
    }

    static func title(_ kind: RecordKind) -> String {
        switch kind {
        case .longestDistance:
            String(localized: "Longest")
        case .fastestOneKilometer:
            String(localized: "Fastest 1 km")
        case .fastestFiveKilometers:
            String(localized: "Fastest 5 km")
        case .bestAveragePace:
            String(localized: "Best avg pace")
        }
    }

    static func emoji(_ kind: RecordKind) -> String {
        switch kind {
        case .longestDistance:
            "📏"
        case .fastestOneKilometer:
            "⚡️"
        case .fastestFiveKilometers:
            "🏁"
        case .bestAveragePace:
            "⏱️"
        }
    }

    static func value(_ record: PersonalRecord) -> String {
        switch record.kind {
        case .longestDistance:
            Format.km(record.value, estimated: record.distanceEstimated)
        case .fastestOneKilometer:
            Format.pace(record.value)
        case .fastestFiveKilometers:
            Format.duration(record.value)
        case .bestAveragePace:
            Format.pace(record.value)
        }
    }
}
