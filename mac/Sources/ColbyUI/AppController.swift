#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import Observation

/// Owns the running `AppModel` and swaps it for demo mode. The app target's scenes read `model`.
@MainActor @Observable
public final class AppController {
    public private(set) var model: AppModel
    public private(set) var error: String?
    /// Bumped when something outside SwiftUI (a notification click) wants the main window shown.
    public private(set) var openMainRequests = 0

    /// - Parameter demo: start in demo mode (`--demo` on the command line, or no Bluetooth wanted).
    public init(demo: Bool = CommandLine.arguments.contains("--demo"), appGroup: String? = nil) {
        Theme.Fonts.register()
        do {
            let runtime = demo ? try Runtime.demo() : try Runtime.live(appGroup: appGroup)
            model = AppModel(runtime: runtime)
            runtime.onOpenAlert = { [weak self] id in self?.openAlert(id) }
        } catch {
            // The database could not open: run the demo so the window still has something to show.
            self.error = "\(error)"
            model = AppModel(runtime: try! Runtime.demo())
        }
        let model = self.model
        Task { await model.start() }
    }

    private func openAlert(_ id: String) {
        if let serial = model.alerts.first(where: { $0.id == id })?.serial { model.selected = serial }
        openMainRequests += 1
    }

    public func switchToDemo() {
        guard !model.isDemo, let runtime = try? Runtime.demo() else { return }
        let old = model
        model = AppModel(runtime: runtime)
        let model = self.model
        Task {
            await old.stop()
            await model.start()
        }
    }
}
#endif
