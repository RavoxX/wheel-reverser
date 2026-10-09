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

    /// Removes this app's Accessibility entry. Ad-hoc signed builds get a new identity with every
    /// version, so an entry left by an older build can look enabled without applying to this one.
    /// After a reset, `request()` registers the current build fresh.
    static func reset() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
