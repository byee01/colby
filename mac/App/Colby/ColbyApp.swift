import ColbyUI
import SwiftUI

@main
struct ColbyApp: App {
    @State private var controller = AppController()

    var body: some Scene {
        Window("Colby", id: "main") {
            MainView(model: controller.model, tryDemo: controller.switchToDemo)
        }
        .defaultSize(width: 1180, height: 760)

        // Closing the window keeps Colby running here, so alerts keep firing (06 §10).
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            MenuBarLabel(model: controller.model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuContent: View {
    var controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarContent(model: controller.model) {
            openWindow(id: "main")
            NSApp.activate()
        }
    }
}
