import ServiceManagement
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !state.isAccessibilityGranted {
                permissionCard
            }

            SettingsSection("Scrolling", footer: "Reversal applies on top of the Natural Scrolling setting in System Settings.") {
                SettingsToggleRow(
                    title: "Reverse Mouse Scrolling",
                    symbol: "computermouse.fill",
                    tint: .blue,
                    isOn: $state.reverseMouse
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Reverse Trackpad Scrolling",
                    symbol: "rectangle.and.hand.point.up.left.fill",
                    tint: .indigo,
                    isOn: $state.reverseTrackpad
                )
            }

            SettingsSection("Mouse Movement", footer: mouseMovementFooter) {
                SettingsToggleRow(
                    title: "Linear Mouse Movement",
                    symbol: "cursorarrow.motionlines",
                    tint: .teal,
                    isOn: $state.linearMouseMovement
                )
                SettingsDivider()
                sensitivityRow
            }

            SettingsSection("General") {
                SettingsToggleRow(
                    title: "Launch at Login",
                    symbol: "power",
                    tint: .gray,
                    isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) })
                )
                if state.loginItemStatus == .requiresApproval {
                    SettingsDivider()
                    HStack {
                        Text("Needs approval in Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Settings") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                SettingsDivider()
                updateRow
            }

            Divider()

            HStack {
                Text("Version \(Bundle.main.shortVersion)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            state.refresh()
            updater.checkIfStale()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Scroll Reverser")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(state.isActive ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusText: String {
        if state.isWaitingForPermission { return "Waiting for permission" }
        return state.isActive ? "Active" : "Paused"
    }

    private var updateRow: some View {
        HStack(spacing: 8) {
            SymbolTile(symbol: "arrow.down", tint: .green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Software Update")
                Text(updateStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch updater.phase {
            case .checking, .installing:
                ProgressView().controlSize(.small)
            case .available:
                Button("Update") { Task { await updater.install() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            default:
                Button("Check") { Task { await updater.check() } }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var sensitivityRow: some View {
        HStack(spacing: 8) {
            SymbolTile(symbol: "gauge.with.dots.needle.33percent", tint: .orange)
            Text("Sensitivity")
            Slider(value: $state.mouseSensitivity, in: MouseMovementController.sensitivityRange)
                .controlSize(.small)
            Text(state.mouseSensitivity, format: .number.precision(.fractionLength(2)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .disabled(!state.linearMouseMovement || !state.supportsMouseSensitivity)
    }

    private var mouseMovementFooter: String {
        let base = "Turns off macOS pointer acceleration for mice. Trackpads are not affected."
        return state.supportsMouseSensitivity ? base : base + " Sensitivity requires macOS 14 or later."
    }

    private var updateStatusText: String {
        switch updater.phase {
        case .idle: "Check GitHub for a newer version"
        case .checking: "Checking…"
        case .upToDate: "Scroll Reverser is up to date"
        case .available(let version): "Version \(version) is available"
        case .installing: "Downloading and verifying…"
        case .failed(let message): message
        }
    }

    private var permissionCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SymbolTile(symbol: "hand.raised.fill", tint: .orange)
                    Text("Accessibility Access Required")
                        .font(.subheadline.weight(.semibold))
                }
                Text("Scroll Reverser needs Accessibility access to change the scroll direction. Enable it in Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Open System Settings") {
                        state.requestAccessibility()
                        AccessibilityPermission.openSystemSettings()
                    }
                    .controlSize(.small)
                }
            }
            .padding(10)
        }
    }
}

// MARK: - Settings-style building blocks

/// A titled group of rows, like a section in System Settings.
private struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            SettingsCard { content }
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let symbol: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                SymbolTile(symbol: symbol, tint: tint)
                Text(title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 38)
    }
}

/// The white-on-color icon squares used throughout System Settings.
private struct SymbolTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}
