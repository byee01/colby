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
        .commands { ProbeCommands(controller: controller) }

        // Closing the window keeps Colby running here, so alerts keep firing (06 §10).
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            MenuBarLabel(model: controller.model)
                .modifier(OpenMainOnRequest(controller: controller))
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar label is always alive, so it opens the window when a notification is clicked.
private struct OpenMainOnRequest: ViewModifier {
    var controller: AppController
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: controller.openMainRequests) {
            openWindow(id: "main")
            NSApp.activate()
        }
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

/// Probe menu: commands on the selected probe.
private struct ProbeCommands: Commands {
    var controller: AppController

    var body: some Commands {
        CommandMenu("Probe") {
            Button("Set Target…") {
                controller.model.targetSheet = controller.model.selectedProbe?.serial
            }
            .keyboardShortcut("t")
            .disabled(controller.model.selectedProbe == nil)
        }
    }
}
