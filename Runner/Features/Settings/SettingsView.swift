import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pendingCount = 0

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ProfileView()
                    } label: {
                        Label(String(localized: "Profile & body metrics"), systemImage: "person.text.rectangle")
                    }
                }

                Section(String(localized: "Daily goal")) {
                    Stepper(value: $model.dailyGoal, in: AppModel.goalRange, step: 10) {
                        HStack {
                            Text(String(localized: "Goal"))
                            Spacer()
                            Text("\(model.dailyGoal) pts")
                                .foregroundStyle(Color.rLime)
                                .bold()
                        }
                    }
                }

                Section(String(localized: "Permissions")) {
                    permissionRow(title: String(localized: "Apple Health"),
                                  ok: model.health.isAvailable && !model.health.writeDenied,
                                  detail: model.health.writeDenied
                                    ? String(localized: "Write access denied — points may be incomplete")
                                    : String(localized: "Connected"))
                    permissionRow(title: String(localized: "Location"),
                                  ok: !model.recorder.authorizationDenied,
                                  detail: model.recorder.authorizationDenied
                                    ? String(localized: "Denied — recording won't work")
                                    : String(localized: "Ready"))
                    if pendingCount > 0 {
                        Label(String(localized: "\(pendingCount) workout(s) waiting to sync to Health"),
                              systemImage: "exclamationmark.arrow.circlepath")
                            .foregroundStyle(Color.rOrange)
                    }
                    Button(String(localized: "Open iOS Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                // Copy is derived from PointsEngine constants so tuning a rule can
                // never leave Settings describing the old math.
                Section(String(localized: "How points work")) {
                    ruleRow("👟", String(localized: "1 pt per \(PointsEngine.stepDivisor) steps (max \(PointsEngine.stepCap)/day)"))
                    ruleRow("🏃", String(localized: "Run: \(Int(PointsEngine.rate(for: .run))) pts per km"))
                    ruleRow("🚶", String(localized: "Walk: \(Int(PointsEngine.rate(for: .walk))) pts per km"))
                    ruleRow("🚴", String(localized: "Bike: \(Int(PointsEngine.rate(for: .bike))) pts per km"))
                    ruleRow("🔥", String(localized: "Streak: +\(PointsEngine.streakBonusPerDay.formatted(.percent)) per gold day, max ×\(PointsEngine.multiplierCap.formatted())"))
                }

                Section(String(localized: "How calories work")) {
                    Text(String(localized: "Calories are estimated from your weight, the activity type, and how fast and long you moved — no heart-rate sensor needed."))
                        .font(.subheadline)
                        .foregroundStyle(Color.rTextSecondary)
                }

                Section {
                    LabeledContent(String(localized: "Version"), value: appVersion)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.rBackground)
            .navigationTitle(String(localized: "Settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .task { pendingCount = (try? model.store.pendingSync().count) ?? 0 }
        }
        .preferredColorScheme(.dark)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func permissionRow(title: String, ok: Bool, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.rTextSecondary)
            }
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color.rTeal : Color.rOrange)
        }
    }

    private func ruleRow(_ emoji: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(emoji)
            Text(text).font(.subheadline)
        }
    }
}
