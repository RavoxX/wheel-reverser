import AppKit
import Security
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ScrollReverser", category: "Updater")

/// Installs new versions from the latest GitHub release.
///
/// Every release carries a DMG and a `<dmg>.sha3-256` checksum file. The DMG is only installed
/// when its SHA3-256 hash matches the checksum, the app inside has a valid code signature,
/// and its bundle identifier and version match what the release promises.
@MainActor
final class Updater: ObservableObject {
    nonisolated static let repository = "RavoxX/wheel-reverser"

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case installing
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle

    private var availableRelease: Release?
    private var lastCheck: Date?

    var isBusy: Bool { phase == .checking || phase == .installing }

    /// Checks at most every few hours; used at launch and whenever the menu opens.
    func checkIfStale() {
        guard !isBusy, availableRelease == nil else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 6 * 60 * 60 { return }
        Task { await check(quietly: true) }
    }

    func check(quietly: Bool = false) async {
        guard !isBusy else { return }
        phase = .checking
        lastCheck = Date()
        do {
            let release = try await Self.fetchLatestRelease()
            if Self.version(release.version, isNewerThan: Bundle.main.shortVersion) {
                availableRelease = release
                phase = .available(version: release.version)
            } else {
                phase = .upToDate
            }
        } catch {
            logger.error("Update check failed: \(error.localizedDescription)")
            // Background checks fail silently, e.g. when offline.
            phase = quietly ? .idle : .failed(error.localizedDescription)
        }
    }

    func install() async {
        guard let release = availableRelease, !isBusy else { return }
        phase = .installing
        let appURL = Bundle.main.bundleURL
        do {
            try await Task.detached { try await Self.downloadAndInstall(release, replacing: appURL) }.value
        } catch {
            logger.error("Update failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
            return
        }

        // An ad-hoc signature changes with every build, so macOS no longer matches the existing
        // Accessibility entry. Clearing it lets the new version ask for access cleanly.
        if Self.isAdHocSigned(appURL), let bundleID = Bundle.main.bundleIdentifier {
            _ = try? Self.run("/usr/bin/tccutil", ["reset", "Accessibility", bundleID])
        }
        BundleInstaller.relaunch(at: appURL)
        NSApp.terminate(nil)
    }

    // MARK: - GitHub

    struct Release: Sendable {
        let version: String
        let dmgURL: URL
        let checksumURL: URL
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let url: URL

            enum CodingKeys: String, CodingKey {
                case name
                case url = "browser_download_url"
            }
        }

        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    nonisolated static func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
            throw UpdateError.missingAsset
        }
        guard let checksum = release.assets.first(where: { $0.name == dmg.name + ".sha3-256" }) else {
            throw UpdateError.missingChecksum
        }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        return Release(version: version, dmgURL: dmg.url, checksumURL: checksum.url)
    }

    nonisolated static func version(_ candidate: String, isNewerThan current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0 ..< max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - Installation

    nonisolated static func downloadAndInstall(_ release: Release, replacing appURL: URL) async throws {
        let fileManager = FileManager.default
        guard fileManager.isWritableFile(atPath: appURL.deletingLastPathComponent().path),
              fileManager.isWritableFile(atPath: appURL.path)
        else { throw UpdateError.notWritable }

        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent("ScrollReverserUpdate-\(UUID().uuidString)")
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: release.checksumURL)
        try validate(checksumResponse)
        let expectedHash = try parseChecksum(checksumData)

        let (download, dmgResponse) = try await URLSession.shared.download(from: release.dmgURL)
        try validate(dmgResponse)
        let dmg = workDirectory.appendingPathComponent("update.dmg")
        try fileManager.moveItem(at: download, to: dmg)

        guard try SHA3.sha256Hex(ofFileAt: dmg) == expectedHash else {
            throw UpdateError.checksumMismatch
        }

        let mountPoint = try attach(dmg, under: workDirectory)
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"]) }

        let contents = try fileManager.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.invalidUpdate("The disk image doesn’t contain the app.")
        }
        try verify(newApp, expectedVersion: release.version)

        let staging = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true
        )
        defer { try? fileManager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(appURL.lastPathComponent)
        try fileManager.copyItem(at: newApp, to: staged)
        BundleInstaller.removeQuarantine(from: staged)
        _ = try fileManager.replaceItemAt(appURL, withItemAt: staged)
    }

    /// Accepts the common `<hash>  <filename>` format as well as a bare hash.
    nonisolated private static func parseChecksum(_ data: Data) throws -> String {
        let hash = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
            throw UpdateError.invalidChecksumFile
        }
        return hash
    }

    nonisolated private static func attach(_ dmg: URL, under directory: URL) throws -> URL {
        let output = try run("/usr/bin/hdiutil", [
            "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", directory.path, "-plist",
        ])
        let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        guard let path = entities.lazy.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.invalidUpdate("The disk image couldn’t be opened.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    nonisolated private static func verify(_ app: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.shortVersion == expectedVersion
        else { throw UpdateError.invalidUpdate("The downloaded app doesn’t match this release.") }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil) == errSecSuccess
        else { throw UpdateError.invalidUpdate("The downloaded app’s code signature is invalid.") }
    }

    nonisolated private static func isAdHocSigned(_ app: URL) -> Bool {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32
        else { return false }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }

    nonisolated private static func validate(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw UpdateError.server(http.statusCode)
        }
    }

    @discardableResult
    nonisolated private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.invalidUpdate("\(URL(fileURLWithPath: executable).lastPathComponent) failed.")
        }
        return output
    }
}

enum UpdateError: LocalizedError {
    case missingAsset
    case missingChecksum
    case invalidChecksumFile
    case checksumMismatch
    case notWritable
    case server(Int)
    case invalidUpdate(String)

    var errorDescription: String? {
        switch self {
        case .missingAsset: "The latest release has no disk image."
        case .missingChecksum: "The latest release has no SHA3-256 checksum."
        case .invalidChecksumFile: "The release checksum file is malformed."
        case .checksumMismatch: "The download failed SHA3-256 verification."
        case .notWritable: "Move Scroll Reverser to the Applications folder to update."
        case .server(let status): "GitHub returned an error (\(status))."
        case .invalidUpdate(let reason): reason
        }
    }
}
