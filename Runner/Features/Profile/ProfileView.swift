import SwiftUI

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var heightText = ""
    @State private var weightText = ""
    @State private var birthDate = Date()
    @State private var hasBirthDate = false
    @State private var sex: BodySex = .unspecified
    // Snapshot of what load() showed, so save() flips isManual only for fields the
    // user actually changed — comparing raw stored Doubles against rounded display
    // strings would flip every field "manual" on an unedited visit.
    @State private var initialHeightText = ""
    @State private var initialWeightText = ""
    @State private var initialBirthDate = Date()
    @State private var initialHasBirthDate = false
    @State private var initialSex: BodySex = .unspecified

    var body: some View {
        List {
            Section {
                Text(String(localized: "Your height, weight, age and sex power the calorie estimates. Values come from Apple Health; edit any of them to override."))
                    .font(.caption)
                    .foregroundStyle(Color.rTextSecondary)
            }

            Section(String(localized: "Body")) {
                metricField(String(localized: "Height (cm)"), text: $heightText)
                metricField(String(localized: "Weight (kg)"), text: $weightText)
                Toggle(String(localized: "Set date of birth"), isOn: $hasBirthDate)
                if hasBirthDate {
                    DatePicker(String(localized: "Date of birth"), selection: $birthDate,
                               in: ...Date(), displayedComponents: .date)
                }
                Picker(String(localized: "Sex"), selection: $sex) {
                    Text(String(localized: "Not set")).tag(BodySex.unspecified)
                    Text(String(localized: "Male")).tag(BodySex.male)
                    Text(String(localized: "Female")).tag(BodySex.female)
                }
            }

            Section {
                Button(String(localized: "Reset to Apple Health")) { resetToHealth() }
                    .foregroundStyle(Color.rTeal)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.rBackground)
        .navigationTitle(String(localized: "Profile"))
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
        .onDisappear(perform: save)
    }

    private func metricField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .foregroundStyle(Color.rLime)
        }
    }

    private func load() {
        guard let row = try? model.profile.row() else { return }
        heightText = row.heightCm.map { String(Int($0.rounded())) } ?? ""
        weightText = row.weightKg.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? ""
        hasBirthDate = row.birthDate != nil
        if let b = row.birthDate { birthDate = b }
        sex = row.sex
        // Remember exactly what we showed, to detect real edits in save().
        initialHeightText = heightText
        initialWeightText = weightText
        initialHasBirthDate = hasBirthDate
        initialBirthDate = birthDate
        initialSex = sex
    }

    private func save() {
        guard let row = try? model.profile.row() else { return }
        if heightText != initialHeightText {
            let v = Double(heightText.replacingOccurrences(of: ",", with: "."))
            row.heightCm = v
            row.isHeightManual = v != nil
        }
        if weightText != initialWeightText {
            let v = Double(weightText.replacingOccurrences(of: ",", with: "."))
            row.weightKg = v
            row.isWeightManual = v != nil
        }
        if hasBirthDate != initialHasBirthDate || (hasBirthDate && birthDate != initialBirthDate) {
            let newBirth = hasBirthDate ? birthDate : nil
            row.birthDate = newBirth
            row.isBirthManual = newBirth != nil
        }
        if sex != initialSex {
            row.sex = sex
            row.isSexManual = sex != .unspecified
        }
        try? model.store.save()
        Task { await model.sync.syncNow() }
    }

    private func resetToHealth() {
        guard let row = try? model.profile.row() else { return }
        row.isHeightManual = false; row.isWeightManual = false
        row.isBirthManual = false; row.isSexManual = false
        try? model.store.save()
        Task {
            await model.profile.refreshFromHealth()
            await model.sync.syncNow()
            load()
        }
    }
}
