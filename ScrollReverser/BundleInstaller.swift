import AppKit
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ScrollReverser", category: "BundleInstaller")

/// File operations shared by moving the app into Applications and installing updates.
enum BundleInstaller {
    /// Clears the download quarantine flag. Without this, Gatekeeper keeps running a copied
    /// app from a randomized read-only location (App Translocation).
    static func removeQuarantine(from bundle: URL) {
        let attribute = "com.apple.quarantine"
        removexattr(bundle.path, attribute, XATTR_NOFOLLOW)
        guard let files = FileManager.default.enumerator(atPath: bundle.path) else { return }
        for case let file as String in files {
            removexattr(bundle.appendingPathComponent(file).path, attribute, XATTR_NOFOLLOW)
        }
    }

    /// Opens the app at `url` once this process has exited, so two instances never run at once.
    /// The caller is expected to terminate right after.
    static func relaunch(at url: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$1\"",
            "sh", url.path,
        ]
        do {
            try process.run()
        } catch {
            logger.error("Failed to relaunch: \(error.localizedDescription)")
        }
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
