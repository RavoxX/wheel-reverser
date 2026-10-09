import AppKit
import ApplicationServices

/// Modifying input events with a `CGEventTap` requires Accessibility access.
enum AccessibilityPermission {
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that points the user to System Settings.
    static func request() {
        // Literal value of `kAXTrustedCheckOptionPrompt`, which isn't concurrency-safe to reference.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
