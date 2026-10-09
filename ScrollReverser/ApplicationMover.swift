import AppKit
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ScrollReverser", category: "ApplicationMover")

/// Offers to move the app into the Applications folder when it's launched from elsewhere,
/// such as Downloads or a disk image, so the login item and Accessibility permission
/// point at a location that won't change.
@MainActor
enum ApplicationMover {
    private static let suppressionKey = "suppressMoveToApplications"

    /// Returns `true` when the app is being relaunched from its new location and should quit.
    static func moveIfNeeded() -> Bool {
        #if DEBUG
        // Builds run from Xcode always live in DerivedData.
        return false
        #else
        let defaults = UserDefaults.standard
        let original = originalBundleURL
        guard !defaults.bool(forKey: suppressionKey), !isInApplicationsFolder(original) else {
            return false
        }

        let alert = NSAlert()
        alert.messageText = "Move to Applications Folder?"
        alert.informativeText = "Scroll Reverser needs to be in your Applications folder to launch at login and keep its permissions."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Do Not Move")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        activate()

        guard alert.runModal() == .alertFirstButtonReturn else {
            if alert.suppressionButton?.state == .on {
                defaults.set(true, forKey: suppressionKey)
            }
            return false
        }

        let destination = applicationsFolder().appendingPathComponent(original.lastPathComponent)
        do {
            try install(from: Bundle.main.bundleURL, to: destination)
        } catch {
            logger.error("Failed to move app: \(error.localizedDescription)")
            let failure = NSAlert(error: error)
            failure.messageText = "Couldn’t Move Scroll Reverser"
            failure.runModal()
            return false
        }

        // Fails harmlessly for read-only locations such as a mounted disk image.
        try? FileManager.default.trashItem(at: original, resultingItemURL: nil)
        BundleInstaller.relaunch(at: destination)
        return true
        #endif
    }

    // MARK: - Steps

    static func isInApplicationsFolder(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return FileManager.default.urls(for: .applicationDirectory, in: .allDomainsMask).contains {
            path.hasPrefix($0.resolvingSymlinksInPath().path + "/")
        }
    }

    /// `/Applications`, or `~/Applications` for users who can't write to it.
    private static func applicationsFolder() -> URL {
        let shared = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: shared.path) {
            return shared
        }
        let personal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try? FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        return personal
    }

    static func install(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            for app in NSWorkspace.shared.runningApplications where app.bundleURL?.standardizedFileURL == destination.standardizedFileURL {
                app.forceTerminate()
            }
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        try fileManager.copyItem(at: source, to: destination)
        BundleInstaller.removeQuarantine(from: destination)
    }

    private static func activate() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Where the user actually put the app. Quarantined apps opened from Downloads run from a
    /// temporary translocated copy, whose original path is only available through Security.framework.
    private static var originalBundleURL: URL {
        let url = Bundle.main.bundleURL
        guard url.path.contains("/AppTranslocation/"),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
        else { return url }

        typealias CreateOriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let createOriginalPath = unsafeBitCast(symbol, to: CreateOriginalPath.self)
        return createOriginalPath(url as CFURL, nil)?.takeRetainedValue() as URL? ?? url
    }
}
