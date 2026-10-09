import SwiftUI

@main
struct ScrollReverserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Scroll Reverser", systemImage: "arrow.up.arrow.down") {
            MenuContentView(state: appDelegate.state, updater: appDelegate.updater)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the app state so the event tap starts at launch, not when the menu is first opened.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Move before asking for Accessibility access, so it's granted to the final location.
        if ApplicationMover.moveIfNeeded() {
            NSApp.terminate(nil)
            return
        }
        state.start()
        updater.checkIfStale()
    }
}
