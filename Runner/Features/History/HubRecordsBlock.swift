import SwiftUI

/// Personal records for the selected activity, linking to the source workout.
struct HubRecordsBlock: View {
    let type: ActivityType
    let records: [PersonalRecord]
    let workoutByID: [UUID: WorkoutRec]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MicroLabel(text: String(localized: "Records"))
            if records.isEmpty {
                SurfaceCard {
                    Text(String(localized: "Not enough data yet — keep at it!"))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.rTextSecondary)
                }
            } else {
                SurfaceCard {
                    VStack(spacing: 10) {
                        ForEach(records, id: \.kind) { record in
                            if let id = record.workoutID, let workout = workoutByID[id] {
                                NavigationLink {
                                    WorkoutDetailView(workout: workout)
                                } label: {
                                    RecordRow(record: record, accent: type.accent,
                                              showsChevron: true)
                                }
                                .buttonStyle(.plain)
                            } else {
                                RecordRow(record: record, accent: .rTextSecondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
