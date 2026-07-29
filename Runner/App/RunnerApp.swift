import SwiftUI
import SwiftData
import AppIntents

@main
struct RunnerApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel.live()
        _model = State(initialValue: model)
        AppDependencyManager.shared.add(dependency: model)
        RunnerAppShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(model)
                .modelContainer(model.store.container)
                .preferredColorScheme(.dark)
                .task { await model.onLaunch() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await model.onForeground() }
                    }
                }
        }
    }
}
