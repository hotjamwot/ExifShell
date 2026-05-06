import SwiftUI

@main
struct ExifShellApp: App {

    init() {
        // Ensure the app is treated as a proper foreground application
        // so it receives keyboard focus on launch. Without this, running
        // via `swift run` can leave the app stranded as a background process.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Bring the app to front so keyboard input goes to
                    // ExifShell, not the background Finder or terminal.
                    DispatchQueue.main.async {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                    // Set a reasonable default window size
                    if let window = NSApplication.shared.windows.first {
                        window.setContentSize(NSSize(width: 800, height: 500))
                    }
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
    }
}