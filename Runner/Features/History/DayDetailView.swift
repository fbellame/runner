import SwiftUI
import SwiftData

struct DayDetailView: View {
    @Environment(AppModel.self) private var model
    let date: Date
    @Query private var ledgers: [DayLedger]
    @Query private var workouts: [WorkoutRec]

    init(date: Date) {
        self.date = date
        let cal = Calendar.current
        let lo = cal.startOfDay(for: date)
        let hi = cal.date(byAdding: .day, value: 1, to: lo)!
        _ledgers = Query(filter: #Predicate { $0.date == lo })
        _workouts = Query(filter: #Predicate { $0.start >= lo && $0.start < hi },
                          sort: \WorkoutRec.start, order: .forward)
    }

    private var day: DayLedger? { ledgers.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                pointsCard
                totalsCard
                workoutsList
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 18)
        }
        .background(Color.rBackground)
        .navigationTitle(date.formatted(.dateTime.weekday(.abbreviated).day().month()))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack {
            Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Spacer()
            if day?.isGold == true {
                Text(String(localized: "GOLD")).font(.system(size: 11, weight: .black)).tracking(1.5)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.rLime.opacity(0.15)))
                    .overlay(Capsule().stroke(Color.rLime, lineWidth: 1))
                    .foregroundStyle(Color.rLime)
            }
        }
        .padding(.top, 8)
    }

    private var pointsCard: some View {
        SurfaceCard {
            VStack(spacing: 8) {
                detailRow(String(localized: "Total points"), "\(day?.totalPoints ?? 0)", .rLime)
                detailRow(String(localized: "From steps (\((day?.steps ?? 0).formatted()))"), "\(day?.stepPoints ?? 0)", .white)
                detailRow(String(localized: "From workouts"), "\(day?.workoutPoints ?? 0)", .white)
                if let m = day?.multiplier, m > 1 {
                    detailRow("🔥 \(String(localized: "Streak bonus"))",
                              "×\(m.formatted(.number.precision(.fractionLength(2))))", .rOrange)
                }
                detailRow(String(localized: "Goal that day"), "\(day?.goalAtThatTime ?? 0)", .rTextSecondary)
            }
        }
    }

    private var totalsCard: some View {
        SurfaceCard {
            VStack(spacing: 8) {
                detailRow("🔥 \(String(localized: "Calories burned"))",
                          (day?.activeCalories ?? 0) > 0 ? "\(Int((day?.activeCalories ?? 0).rounded())) \(String(localized: "kcal"))" : "—",
                          .rOrange)
                detailRow("📏 \(String(localized: "Distance"))", Format.km(day?.distanceMeters ?? 0), .white)
                detailRow("⏱️ \(String(localized: "Active time"))", Format.duration(day?.activeSeconds ?? 0), .white)
            }
        }
    }

    @ViewBuilder private var workoutsList: some View {
        if !workouts.isEmpty {
            MicroLabel(text: String(localized: "Workouts"))
            ForEach(workouts) { workout in
                NavigationLink { WorkoutDetailView(workout: workout) } label: {
                    SurfaceCard {
                        HStack {
                            Text(workout.type.emoji).font(.system(size: 20))
                            Text("\(workout.type.localizedName) · \(Format.km(workout.distanceMeters))")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            Spacer()
                            Text("+\(workout.points)").font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(workout.type.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String, _ accent: Color) -> some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(.white)
            Spacer()
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(accent)
        }
    }
}
