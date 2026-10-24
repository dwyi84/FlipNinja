import AppKit
import SwiftUI

/// Single-screen, scroll-free 320pt popover — follows the NightOwl layout:
/// header / primary toggle / angle / remap / optional permission / footer.
struct MainPopoverView: View {
    @ObservedObject var display: DisplayManager
    @ObservedObject var settings: AppSettings
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var updater: UpdaterViewModel

    var onClose: () -> Void
    var onTogglePortrait: () -> Void
    var onRequestAccessibility: () -> Void
    var onRetryEventTap: () -> Void
    var onQuit: () -> Void

    private let coffeeURL = URL(string: "https://buymeacoffee.com/dwyi84d")!

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                primarySection
                angleSection
                remapSection
                if !settings.accessibilityGranted || !settings.eventTapActive {
                    accessibilityRow
                }
            }
            .padding(16)

            Divider()
            shortcutGuide
            footer
        }
        .frame(width: 320)
        .onExitCommand(perform: onClose)
        .confirmationDialog(
            "Update to v\(updater.pendingUpdateVersion ?? "")?",
            isPresented: $updater.showUpdateConfirm,
            titleVisibility: .visible
        ) {
            Button("Update Now") {
                updater.installNow()
            }
            Button("Cancel", role: .cancel) {
                updater.cancelPrompt()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            FlipNinjaGlyph(angle: display.isPortrait ? display.activeAngle : 0)
                .frame(width: 18, height: 18)
                .foregroundStyle(.tint)

            Text("FlipNinja")
                .font(.headline)

            Text("v\(UpdaterViewModel.currentVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            updateIndicator
                .frame(height: 20)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var updateIndicator: some View {
        switch updater.updateState {
        case .checking:
            ProgressView()
                .controlSize(.mini)
                .help("Checking for updates…")
        case .downloading:
            ProgressView()
                .controlSize(.mini)
                .help("Downloading update…")
        case .upToDate:
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle")
                Text("Up to date")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        case .updateAvailable:
            Button("Update Available") {
                updater.showUpdateConfirm = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Update to v\(updater.pendingUpdateVersion ?? "")")
        case .idle:
            Button("Check for Updates") {
                updater.checkForUpdates()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Check for updates")
        case .failed:
            Button("Check Again") {
                updater.checkForUpdates()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Check for updates again")
        }
    }

    // MARK: - Primary

    private var primarySection: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Portrait Mode")
                    .font(.title3.weight(.semibold))
                Text(display.isPortrait
                     ? "Display rotated \(display.activeAngle)°; scrolling matched."
                     : "Standard landscape; scrolling normal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Toggle("Portrait Mode", isOn: Binding(
                get: { display.isPortrait },
                set: { newValue in
                    guard newValue != display.isPortrait else { return }
                    onTogglePortrait()
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.large)
            .labelsHidden()
        }
    }

    // MARK: - Angle

    private var angleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Portrait Angle")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker(
                "Portrait Angle",
                selection: Binding(
                    get: { display.portraitAngle },
                    set: { angle in
                        let rotates = display.isPortrait && angle != display.portraitAngle
                        if rotates { onClose() }
                        display.selectPortraitAngle(angle)
                    }
                )
            ) {
                ForEach(PortraitAngle.allCases) { angle in
                    Text(angle.shortLabel).tag(angle)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(display.portraitAngle.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Remap

    private var remapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $settings.scrollRotation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rotate Scrolling with Display")
                        .font(.callout)
                    Text("Two-finger scrolling follows the rotated screen.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    // MARK: - Permissions

    private var needsPermissionGrant: Bool {
        !settings.accessibilityGranted
    }

    private var permissionTitle: String {
        if !settings.accessibilityGranted { return "Accessibility required" }
        return "Input tap is not running"
    }

    private var permissionDetail: String {
        if !settings.accessibilityGranted {
            return "Required for the shortcut and scroll rotation."
        }
        return "Retry, or re-enable FlipNinja in System Settings."
    }

    private var accessibilityRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(permissionTitle)
                    .font(.system(size: 12, weight: .medium))
                Text(permissionDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if needsPermissionGrant {
                Button("Grant", action: onRequestAccessibility)
                    .controlSize(.small)
            } else {
                Button("Retry", action: onRetryEventTap)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
    }

    // MARK: - Shortcut guide

    /// Keycap-style hint so the toggle shortcut is discoverable without
    /// opening the status menu.
    private var shortcutGuide: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Portrait Toggle")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 4) {
                keycap("⌃")
                keycap("Fn")
                keycap("O")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .foregroundStyle(.secondary)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Link(destination: coffeeURL) {
                    HStack(spacing: 6) {
                        Text("☕")
                        Text("Buy me a coffee")
                            .font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(red: 1.0, green: 0.87, blue: 0.0))
                    )
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Quit", action: onQuit)
                    .controlSize(.small)
            }

            HStack {
                Text("Launch at Login")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel("Launch at Login")
            }

            Text("Crafted by MelissaSoft")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
