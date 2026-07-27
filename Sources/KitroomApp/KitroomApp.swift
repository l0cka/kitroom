import SwiftUI

@main
struct KitroomApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    await model.start()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 760)
    }
}
