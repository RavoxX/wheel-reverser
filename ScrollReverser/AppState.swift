import Foundation
import ServiceManagement
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ScrollReverser", category: "AppState")

/// User preferences plus the coordination between them, the event tap and system permissions.
@MainActor
final class AppState: ObservableObject {
    private enum Key {
        static let reverseMouse = "reverseMouse"
        static let reverseTrackpad = "reverseTrackpad"
    }

    @Published var reverseMouse: Bool {
        didSet { preferenceChanged(Key.reverseMouse, reverseMouse) }
    }

    @Published var reverseTrackpad: Bool {
        didSet { preferenceChanged(Key.reverseTrackpad, reverseTrackpad) }
    }

    @Published private(set) var isAccessibilityGranted = AccessibilityPermission.isGranted
    @Published private(set) var loginItemStatus = SMAppService.mainApp.status

    var isActive: Bool { isAccessibilityGranted && (reverseMouse || reverseTrackpad) }
    var launchAtLogin: Bool { loginItemStatus == .enabled }

    private let defaults: UserDefaults
    private let eventTap = ScrollEventTap()
    private var permissionWatcher: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.reverseMouse: true, Key.reverseTrackpad: false])
        reverseMouse = defaults.bool(forKey: Key.reverseMouse)
        reverseTrackpad = defaults.bool(forKey: Key.reverseTrackpad)

        eventTap.onPermissionLost = { [weak self] in
            self?.refreshPermission()
        }
    }

    func start() {
        if !isAccessibilityGranted && (reverseMouse || reverseTrackpad) {
            requestAccessibility()
        }
        updateEventTap()
    }

    /// Re-reads state the user may have changed in System Settings while the app was running.
    func refresh() {
        refreshPermission()
        loginItemStatus = SMAppService.mainApp.status
    }

    func requestAccessibility() {
        AccessibilityPermission.request()
        watchForPermission()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Failed to update login item: \(error.localizedDescription)")
        }
        loginItemStatus = SMAppService.mainApp.status
    }

    // MARK: - Private

    private func preferenceChanged(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: key)
        if value && !isAccessibilityGranted {
            requestAccessibility()
        }
        updateEventTap()
    }

    private func refreshPermission() {
        let granted = AccessibilityPermission.isGranted
        guard granted != isAccessibilityGranted else { return }
        isAccessibilityGranted = granted
        if !granted {
            watchForPermission()
        }
        updateEventTap()
    }

    /// The tap only runs while it has work to do, so idle scrolling stays untouched.
    private func updateEventTap() {
        eventTap.reverseMouse = reverseMouse
        eventTap.reverseTrackpad = reverseTrackpad

        guard isAccessibilityGranted, reverseMouse || reverseTrackpad else {
            eventTap.stop()
            return
        }
        if !eventTap.start() {
            logger.error("Failed to create scroll event tap")
        }
    }

    /// macOS doesn't notify apps when Accessibility access is granted, so poll until it is.
    private func watchForPermission() {
        guard permissionWatcher == nil else { return }
        permissionWatcher = Task { [weak self] in
            while !Task.isCancelled && !AccessibilityPermission.isGranted {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self else { return }
            self.permissionWatcher = nil
            self.refreshPermission()
        }
    }
}
