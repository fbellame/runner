import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottom) {
            Group {
                switch model.selectedTab {
                case .today:
                    TodayView()
                case .history:
                    HistoryView()
                case .routes:
                    RoutesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.rBackground)

            tabBar
        }
        .ignoresSafeArea(.keyboard)
        .fullScreenCover(isPresented: $model.showRecordSheet) {
            RecordView(resumeFrom: model.pendingResume)
                .onDisappear { model.pendingResume = nil }
        }
        .sheet(item: $model.pendingCelebration) { workout in
            CelebrationSheet(workout: workout) { model.clearPendingCelebration() }
        }
        .alert("Resume your workout?", isPresented: resumeAlertBinding) {
            Button("Resume") { model.showRecordSheet = true }
            Button("Save as-is") {
                Task { await model.saveCheckpointedWorkout() }
            }
            Button("Discard", role: .destructive) {
                model.discardPendingResume()
            }
        } message: {
            Text("Runner was interrupted mid-workout. Your progress was saved.")
        }
    }

    private var resumeAlertBinding: Binding<Bool> {
        Binding(get: { model.pendingResume != nil && !model.showRecordSheet },
                set: { _ in })
    }

    private var tabBar: some View {
        HStack {
            tabButton(.today, icon: "bolt.fill", label: String(localized: "Today"))
            tabButton(.history, icon: "chart.bar.fill", label: String(localized: "History"))
            recordButton
            tabButton(.routes, icon: "map.fill", label: String(localized: "Routes"))
            settingsButton
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(
            Rectangle()
                .fill(Color.rBackground.opacity(0.92))
                .overlay(Rectangle().fill(Color.rBorder).frame(height: 1), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func tabButton(_ tab: AppTab, icon: String, label: String) -> some View {
        Button {
            model.selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(model.selectedTab == tab ? Color.rLime : Color.rTextSecondary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var recordButton: some View {
        Button {
            model.showRecordSheet = true
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.rBackground)
                .frame(width: 58, height: 58)
                .background(
                    Circle().fill(LinearGradient(colors: [.rLime, .rTeal],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                )
                .modifier(GlowShadow(color: .rLime))
        }
        .buttonStyle(.plain)
        .offset(y: -18)
        .accessibilityLabel(String(localized: "Record a workout"))
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 19, weight: .semibold))
                Text(String(localized: "Settings"))
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color.rTextSecondary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

/// The post-workout celebration, with its own fetch.
///
/// This query used to live on `RootTabView`, which meant every launch and every
/// root body pass materialised all 766 `WorkoutRec` rows — 47 µs each — to have
/// an achievement history ready for a sheet that is open for a few seconds after
/// a run and never otherwise. Fetching it here scopes the cost to the moment it
/// is actually needed.
private struct CelebrationSheet: View {
    let workout: RecordedWorkout
    let onDismiss: () -> Void

    @Query(sort: \WorkoutRec.start, order: .reverse)
    private var workouts: [WorkoutRec]

    var body: some View {
        let candidate = PendingCelebrationPresentation.candidate(from: workout)
        let history = workouts
            .filter {
                !($0.type == workout.type &&
                  $0.start == workout.start &&
                  $0.end == workout.end)
            }
            .map(ActivityWorkoutSummary.init(workout:))
        WorkoutSummaryView(
            workout: workout,
            achievements: TrophyMath.achievements(
                history: history,
                candidate: candidate
            ),
            isSaving: false,
            isAlreadySaved: true,
            onSave: onDismiss,
            onDiscard: onDismiss
        )
    }
}
