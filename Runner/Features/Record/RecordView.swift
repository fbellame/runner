import SwiftUI
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

    private var recorder: WorkoutRecorder { model.recorder }
    private var isActive: Bool { recorder.state != .idle }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                UserAnnotation()
                if recorder.route.count >= 2 {
                    MapPolyline(coordinates: recorder.route.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    })
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
                               onSave: { Task { await save(workout) } },
                               onDiscard: {
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

    private var setupPanel: some View {
        VStack(spacing: 18) {
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
                recorder.start(activity: selectedActivity)
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
            if recorder.state == .autoPaused {
                Label(String(localized: "Auto-paused"), systemImage: "pause.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.rOrange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.rOrange.opacity(0.15)))
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(recorder.livePoints)")
                    .font(.system(size: 54, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.rLime)
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.4), value: recorder.livePoints)
                    .modifier(GlowShadow(color: .rLime))
                Text("PTS")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.rLime)
            }

            HStack(spacing: 10) {
                hudStat(String(localized: "Time"), Format.duration(recorder.movingSeconds))
                hudStat(String(localized: "Distance"), Format.km(recorder.distanceMeters))
                hudStat(String(localized: "Pace"), Format.pace(recorder.paceSecondsPerKm))
            }

            HStack(spacing: 12) {
                Button {
                    if recorder.state == .manuallyPaused {
                        recorder.resumeManually()
                    } else {
                        recorder.pauseManually()
                    }
                } label: {
                    Image(systemName: recorder.state == .manuallyPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.rSurface))
                        .overlay(Circle().stroke(Color.rBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                SlideToFinish {
                    finished = recorder.finish()
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
            Button(String(localized: "Cancel")) { dismiss() }
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
        let points = PointsEngine.workoutPoints(type: workout.type,
                                                distanceMeters: workout.distanceMeters)
        let routeData = try? workout.route.encoded()
        do {
            let hkID = try await model.health.saveWorkout(workout, points: points)
            _ = try? model.store.upsertWorkout(id: hkID,
                                               type: workout.type,
                                               start: workout.start,
                                               end: workout.end,
                                               movingSeconds: workout.movingSeconds,
                                               distanceMeters: workout.distanceMeters,
                                               points: points,
                                               routeData: routeData,
                                               splitSeconds: workout.splitSeconds,
                                               source: "runner",
                                               hkSynced: true)
            await model.sync.syncNow()
            finished = nil
            dismiss()
        } catch {
            _ = try? model.store.upsertWorkout(id: UUID(),
                                               type: workout.type,
                                               start: workout.start,
                                               end: workout.end,
                                               movingSeconds: workout.movingSeconds,
                                               distanceMeters: workout.distanceMeters,
                                               points: points,
                                               routeData: routeData,
                                               splitSeconds: workout.splitSeconds,
                                               source: "runner",
                                               hkSynced: false)
            await model.sync.syncNow()
            finished = nil
            saveFailedMessage = error.localizedDescription
        }
    }
}

extension RecordedWorkout: Identifiable {
    var id: Date { start }
}
