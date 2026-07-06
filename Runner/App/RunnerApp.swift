import SwiftUI
import SwiftData

@main
struct RunnerApp: App {
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

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
