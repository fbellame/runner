import SwiftUI
import SwiftData
import MapKit
import UIKit

struct RecordView: View {
    let resumeFrom: SessionCheckpoint?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedActivity: ActivityType = .run
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var finished: RecordedWorkout?
    @State private var saveFailedMessage: String?
    @State private var isSaving = false
    @Query(sort: \WorkoutRec.start, order: .reverse) private var workouts: [WorkoutRec]

    private var recorder: WorkoutRecorder { model.recorder }
    private var isActive: Bool { recorder.state != .idle }
    /// Mirrors `resumeManually()`'s own guard so the icon can never promise
    /// something the tap then refuses. An armed session sits in `.autoPaused` but
    /// has nothing to resume, so it keeps showing "pause" exactly as it did.
    private var canResume: Bool {
        !recorder.isArmed
            && (recorder.state == .manuallyPaused || recorder.state == .autoPaused)
    }

    private var workoutSummaries: [ActivityWorkoutSummary] {
        workouts.map(ActivityWorkoutSummary.init(workout:))
    }

    private func candidate(from workout: RecordedWorkout) -> ActivityWorkoutSummary {
        ActivityWorkoutSummary(id: UUID(),
                               type: workout.type,
                               date: workout.start,
                               distanceMeters: workout.distanceMeters,
                               distanceEstimated: workout.distanceEstimated,
                               movingSeconds: workout.movingSeconds,
                               points: PointsEngine.workoutPoints(type: workout.type,
                                                                  distanceMeters: workout.distanceMeters),
                               calories: 0,
                               splitSeconds: workout.splitSeconds,
                               hasRoute: !workout.route.isEmpty)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                UserAnnotation()
                if recorder.route.count >= 2 {
                    MapPolyline(coordinates: recorder.route.map(\.coordinate))
                    .stroke(Color.rLime,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .ignoresSafeArea()

            if recorder.authorizationDenied {
                deniedOverlay
            } else if isActive {
                activeHUD
            } else {
                setupPanel
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            recorder.requestPermission()
            recorder.onKmSplit = { _ in Haptics.kmSplit() }
            if let resumeFrom {
                recorder.start(activity: resumeFrom.activity, resumeFrom: resumeFrom)
            }
        }
        .sheet(item: $finished) { workout in
            WorkoutSummaryView(workout: workout,
                               achievements: TrophyMath.achievements(history: workoutSummaries,
                                                                     candidate: candidate(from: workout)),
                               isSaving: isSaving,
                               onSave: { Task { await save(workout) } },
                               onDiscard: {
                                   recorder.discard()
                                   finished = nil
                                   dismiss()
                               })
        }
        .alert(String(localized: "Saved locally"),
               isPresented: Binding(get: { saveFailedMessage != nil },
                                    set: { if !$0 { saveFailedMessage = nil; dismiss() } })) {
            Button(String(localized: "Done"), role: .cancel) {}
        } message: {
            let detail = saveFailedMessage ?? ""
            Text(String(localized: "Apple Health refused the save (\(detail)). The workout is kept in Runner and will retry automatically."))
        }
    }

    private var reducedAccuracyBanner: some View {
        VStack(spacing: 6) {
            Label(String(localized: "Precise Location is off — distance and route can't be recorded."),
                  systemImage: "location.slash.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.rOrange)
                .multilineTextAlignment(.center)
            Button(String(localized: "Open iOS Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.rLime)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.rOrange.opacity(0.12)))
    }

    private var setupPanel: some View {
        VStack(spacing: 18) {
            if recorder.reducedAccuracy {
                reducedAccuracyBanner
            }
            HStack(spacing: 10) {
                ForEach(ActivityType.allCases, id: \.self) { activity in
                    Button {
                        selectedActivity = activity
                    } label: {
                        VStack(spacing: 6) {
                            Text(activity.emoji)
                                .font(.system(size: 26))
                            Text(activity.localizedName)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(selectedActivity == activity
                                      ? activity.accent.opacity(0.18)
                                      : Color.rSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(selectedActivity == activity ? activity.accent : Color.rBorder,
                                        lineWidth: selectedActivity == activity ? 2 : 1)
                        )
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                recorder.start(activity: selectedActivity, armed: true)
            } label: {
                Text(String(localized: "GO"))
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(Color.rBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .background(
                        Capsule().fill(LinearGradient(colors: [.rLime, .rTeal],
                                                      startPoint: .leading,
                                                      endPoint: .trailing))
                    )
                    .modifier(GlowShadow(color: .rLime))
            }
            .buttonStyle(.plain)

            Button(String(localized: "Cancel")) { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.rTextSecondary)
        }
        .padding(18)
        .background(panelBackground)
    }

    private var activeHUD: some View {
        VStack(spacing: 14) {
            if recorder.reducedAccuracy {
                reducedAccuracyBanner
            }
            if recorder.isArmed {
                Label(String(localized: "Ready — start moving"), systemImage: "figure.run")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.rLime)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.rLime.opacity(0.15)))
            } else if recorder.state == .autoPaused {
                Label(String(localized: "Auto-paused"), systemImage: "pause.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.rOrange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.rOrange.opacity(0.15)))
            }

            GlowNumber(value: recorder.livePoints, unitLabel: "PTS",
                       size: 54, unitSize: 14, numberColor: .rLime)
                .animation(.spring(duration: 0.4), value: recorder.livePoints)

            HStack(spacing: 10) {
                hudStat(String(localized: "Time"), Format.duration(recorder.movingSeconds))
                hudStat(String(localized: "Distance"), Format.km(recorder.distanceMeters))
                hudStat(String(localized: "Pace"), Format.pace(recorder.paceSecondsPerKm))
            }

            HStack(spacing: 12) {
                Button {
                    if canResume {
                        recorder.resumeManually()
                    } else {
                        recorder.pauseManually()
                    }
                } label: {
                    Image(systemName: canResume ? "play.fill" : "pause.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(recorder.isArmed ? Color.rTextSecondary : .white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.rSurface))
                        .overlay(Circle().stroke(Color.rBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(recorder.isArmed)

                SlideToFinish {
                    finished = recorder.finish(endingAt: recorder.lastMovingAt)
                }
            }
        }
        .padding(18)
        .background(panelBackground)
    }

    private var deniedOverlay: some View {
        VStack(spacing: 12) {
            Text("📍")
                .font(.system(size: 40))
            Text(String(localized: "Runner needs location access to draw your parcours."))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Button(String(localized: "Open iOS Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Color.rLime)
            Button(String(localized: "Cancel")) {
                recorder.cancelAfterAuthorizationDenial()
                dismiss()
            }
                .font(.system(size: 14))
                .foregroundStyle(Color.rTextSecondary)
        }
        .padding(24)
        .background(panelBackground)
        .padding(.bottom, 40)
    }

    private func hudStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            MicroLabel(text: label)
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.rSurface.opacity(0.85)))
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(Color.rBackground.opacity(0.92))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.rBorder, lineWidth: 1))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .ignoresSafeArea(edges: .bottom)
    }

    private func save(_ workout: RecordedWorkout) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        // One shared save path (local-first, then HealthKit) lives on the coordinator.
        let outcome = await model.sync.saveRecorded(workout)
        // CRITICAL 5: the same "local write failed but we said it saved" bug the
        // Lock-Screen path had. Until the durable copy exists, keep the recovery
        // checkpoint, say nothing out loud, keep the summary sheet open with its
        // Save button live, and show why.
        guard outcome.isLocallyDurable else {
            saveFailedMessage = outcome.durableFailure
            return
        }
        model.checkpoints.clear()
        // IN-APP save path only. Confirms out loud that the run was actually
        // captured — otherwise the last thing a hands-free user hears is
        // whatever the recorder announced before finishing, which may be the
        // opposite of what just happened (e.g. "Resumed"). `completeSave()`
        // (Task 8) also ends the Live Activity here, using the final stats
        // `finish()` captured; it speaks through the existing `announceSaved()`
        // rather than announcing a second time, so this line does not say
        // "Run saved. Run saved." Task 12's Lock-Screen intent save is a
        // separate call site that needs its own cue, but exactly once.
        model.recorder.completeSave()
        finished = nil
        // A HealthKit-only failure still counts as saved: the local store is the
        // durable copy and `retryPendingSaves` pushes it later.
        if let failure = outcome.healthKitFailure {
            saveFailedMessage = failure
        } else {
            dismiss()
        }
    }
}

extension RecordedWorkout: Identifiable {
    var id: Date { start }
}
