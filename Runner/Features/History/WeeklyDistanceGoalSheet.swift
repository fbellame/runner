import SwiftUI

struct WeeklyDistanceGoalSheet: View {
    let type: ActivityType
    let currentGoal: Double?
    let onSave: (Double?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kilometers: Double

    init(type: ActivityType, currentGoal: Double?, onSave: @escaping (Double?) -> Void) {
        self.type = type
        self.currentGoal = currentGoal
        self.onSave = onSave
        _kilometers = State(initialValue: currentGoal ?? type.suggestedWeeklyDistanceGoal)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $kilometers,
                            in: type.weeklyDistanceGoalRange,
                            step: type.weeklyDistanceGoalStep) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(type.localizedName)
                                .font(.headline)
                            Text(String(format: String(localized: "%@ km per week"),
                                        DistanceGoalFormat.number(kilometers)))
                                .foregroundStyle(type.accent)
                        }
                    }
                }

                if currentGoal != nil {
                    Section {
                        Button(String(localized: "Clear goal"), role: .destructive) {
                            onSave(nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Weekly distance goal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        onSave(kilometers)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private extension ActivityType {
    var weeklyDistanceGoalStep: Double {
        switch self {
        case .run, .walk: 1
        case .bike: 5
        }
    }

    var weeklyDistanceGoalRange: ClosedRange<Double> {
        switch self {
        case .run, .walk: 1...200
        case .bike: 5...500
        }
    }

    var suggestedWeeklyDistanceGoal: Double {
        switch self {
        case .run: 15
        case .walk: 10
        case .bike: 50
        }
    }
}
