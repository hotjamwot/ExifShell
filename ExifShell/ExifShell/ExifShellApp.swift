import SwiftUI

// ============================================================================
// ExifShellApp
// ============================================================================
// @main entry point for ExifShell. Sets the activation policy so the app
// behaves as a proper foreground application (important when launched via
// `swift run`), brings itself to front on launch, and sets a generous
// default window size for metadata preview.
//
// Types referenced:
//   - ContentView (root view, the only view in the scene)
//
// Configuration:
//   - Activation policy: .regular (foreground app)
//   - Default window size: 1100 × 680
//   - Window resizability: .contentSize (respects child view min sizes)
//   - Window style: .titleBar (standard macOS title bar)
// ============================================================================

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
                    // Set a generous default window size for metadata preview
                    if let window = NSApplication.shared.windows.first {
                        window.setContentSize(NSSize(width: 1100, height: 680))
                    }
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
    }
}