// colby-shots: renders the app's views offscreen against demo mode and writes PNGs (no screen capture needed).
//
//   swift run colby-shots [--out DIR] [--seconds N]
//
// Waits N seconds (default 8) of real time so the demo probes connect and backfill, then renders.
#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import ColbyUI
import CombustionCodec
import SwiftUI

@MainActor
func render<V: View>(_ view: V, size: CGSize, to url: URL) {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
        .environment(\.staticRender, true))
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        print("failed: \(url.lastPathComponent)")
        return
    }
    try? png.write(to: url)
    print("wrote \(url.path)")
}

@MainActor
func run() async {
    let args = CommandLine.arguments
    let out = URL(fileURLWithPath: args.firstIndex(of: "--out").map { args[$0 + 1] } ?? "shots")
    let seconds = args.firstIndex(of: "--seconds").flatMap { Double(args[$0 + 1]) } ?? 8
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let controller = AppController(demo: true)
    try? await Task.sleep(for: .seconds(seconds))
    let model = controller.model
    render(MainView(model: model), size: CGSize(width: 1180, height: 760), to: out.appendingPathComponent("main.png"))
    // Trip a probe alarm (core low above the current core) so the alert band shows.
    try? await model.app.commands.setAlarm(ProbeSerial(0x1000_0001), channel: .core, kind: .low, temperature: 90)
    try? await Task.sleep(for: .seconds(7))
    // The window's minimum content size, with an alert showing (the tallest layout).
    render(MainView(model: model), size: CGSize(width: 900, height: 640), to: out.appendingPathComponent("main-min.png"))
    render(MenuBarContent(model: model) {}, size: CGSize(width: 340, height: 420),
           to: out.appendingPathComponent("popover.png"))
    render(MenuBarLabel(model: model).foregroundStyle(.white).padding(6).background(Color.black),
           size: CGSize(width: 260, height: 30), to: out.appendingPathComponent("menubar.png"))
}

await run()
exit(0)
#else
print("colby-shots needs macOS")
#endif
