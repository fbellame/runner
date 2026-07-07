import SwiftUI

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var heightText = ""
    @State private var weightText = ""
    @State private var birthDate = Date()
    @State private var hasBirthDate = false
    @State private var sex: BodySex = .unspecified

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
        if let b = row.birthDate { birthDate = b; hasBirthDate = true }
        sex = row.sex
    }

    private func save() {
        guard let row = try? model.profile.row() else { return }
        let newHeight = Double(heightText.replacingOccurrences(of: ",", with: "."))
        if newHeight != row.heightCm { row.heightCm = newHeight; row.isHeightManual = newHeight != nil }
        let newWeight = Double(weightText.replacingOccurrences(of: ",", with: "."))
        if newWeight != row.weightKg { row.weightKg = newWeight; row.isWeightManual = newWeight != nil }
        let newBirth = hasBirthDate ? birthDate : nil
        if newBirth != row.birthDate { row.birthDate = newBirth; row.isBirthManual = newBirth != nil }
        if sex != row.sex { row.sex = sex; row.isSexManual = sex != .unspecified }
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
