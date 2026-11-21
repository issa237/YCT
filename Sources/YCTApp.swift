import AppKit
import SwiftUI

@main
struct YCTApp: App {
    @StateObject private var engine = ClipEngine()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("YCT — YouTube High-Moment Clipper") {
            ContentView(engine: engine)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
