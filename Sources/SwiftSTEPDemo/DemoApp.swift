import SwiftUI
import AppKit

@main
struct SwiftSTEPDemoApp: App {
    @StateObject private var viewer = Viewer()

    init() {
        // Running from `swift run` there is no app bundle: ask for a regular, focusable app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("SwiftSTEP Demo", id: "main") {
            ContentView(viewer: viewer)
                .frame(minWidth: 480, minHeight: 360)
                .task {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    viewer.openInitialFile()
                }
        }
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { viewer.isImporting = true }
                    .keyboardShortcut("o")
            }
        }
    }
}
