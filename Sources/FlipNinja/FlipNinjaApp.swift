import AppKit
import Combine
import SwiftUI

@main
struct FlipNinjaApp {
    @MainActor private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let settings = AppSettings()
    private let display = DisplayManager()
    private let launchAtLogin = LaunchAtLoginManager.shared
    private let updater = UpdaterViewModel()

    private lazy var eventTap = EventTapManager { [weak self] in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self?.togglePortrait()
            }
        }
    }

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var rightClickMenu: NSMenu?

    private var portraitMenuItem: NSMenuItem?
    private var angleSubmenu: NSMenu?
    private var remapMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?

    private var cancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?
    private var screenChangeWorkItem: DispatchWorkItem?
    private var systemObservers: [NSObjectProtocol] = []
    private var didShowTapFailure = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfAlreadyRunning() {
            return
        }

        NSApp.mainMenu = NSMenu()

        setupStatusItem()
        setupPopover()
        wireState()
        observeSystemEvents()

        display.syncFromSystem()
        refreshStatusItem()
        refreshMenus()

        startEventTapIfPossible()
        showOnboardingIfNeeded()
        updater.checkForUpdates()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        screenChangeWorkItem?.cancel()
        eventTap.stop()
        display.restoreLandscape()
    }

    // MARK: - Wiring

    /// Prevents a second copy (for example from `dist/` and `~/Applications`)
    /// from installing a second event tap and fighting over the display.
    private func terminateIfAlreadyRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let other = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != currentPID }) else {
            return false
        }
        other.activate(options: [])
        NSApp.terminate(nil)
        return true
    }

    private func wireState() {
        display.onStateChange = { [weak self] in
            guard let self else { return }
            self.refreshStatusItem()
            self.refreshMenus()
            self.applyInputConfiguration()
        }
        display.onError = { [weak self] message in
            self?.presentRotationError(message)
        }

        settings.$scrollRotation
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyInputConfiguration()
                self.refreshMenus()
            }
            .store(in: &cancellables)
    }

    private func applyInputConfiguration() {
        eventTap.update(
            isPortrait: display.isPortrait,
            rotation: display.isPortrait ? display.activeAngle : 0,
            scrollEnabled: settings.scrollRotation
        )
    }

    private func observeSystemEvents() {
        let screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleSystemSync()
            }
        }

        let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleSystemSync()
            }
        }

        let activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recheckPermissions()
            }
        }

        systemObservers = [screenObserver, wakeObserver, activationObserver]
    }

    private func scheduleSystemSync() {
        screenChangeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Rotation and display reconfiguration are asynchronous; give
                // the window server a moment before trusting its answer.
                if self.popover?.isShown == true {
                    self.closePopover()
                }
                self.display.syncFromSystem()
                self.applyInputConfiguration()
            }
        }
        screenChangeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        guard let button = item.button else { return }
        button.image = FlipNinjaMenuBarIcon.image(angle: 0)
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        rightClickMenu = makeRightClickMenu()
    }

    private func makeRightClickMenu() -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(
            title: "Open FlipNinja",
            action: #selector(showPopoverFromMenu),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let rotate = NSMenuItem(
            title: "Portrait Mode",
            action: #selector(togglePortraitFromMenu),
            keyEquivalent: ""
        )
        rotate.target = self
        portraitMenuItem = rotate
        menu.addItem(rotate)

        let angleItem = NSMenuItem(title: "Portrait Angle", action: nil, keyEquivalent: "")
        let angles = NSMenu()
        for angle in PortraitAngle.allCases {
            let item = NSMenuItem(
                title: angle.label,
                action: #selector(selectAngleFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = angle.rawValue
            item.image = FlipNinjaMenuBarIcon.image(angle: angle.rawValue, length: 14)
            angles.addItem(item)
        }
        angleItem.submenu = angles
        angleSubmenu = angles
        menu.addItem(angleItem)

        let remap = NSMenuItem(
            title: "Rotate Scrolling with Display",
            action: #selector(toggleRemapFromMenu),
            keyEquivalent: ""
        )
        remap.target = self
        remapMenuItem = remap
        menu.addItem(remap)

        menu.addItem(.separator())

        let check = NSMenuItem(
            title: "Check for Updates",
            action: #selector(checkForUpdatesFromMenu),
            keyEquivalent: ""
        )
        check.target = self
        menu.addItem(check)

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLoginFromMenu),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchAtLoginMenuItem = launchItem
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let guide = NSMenuItem(
            title: "Control + Fn + O — Toggle Portrait Mode",
            action: nil,
            keyEquivalent: ""
        )
        guide.isEnabled = false
        guide.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        menu.addItem(guide)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit FlipNinja",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func refreshStatusItem() {
        let angle = display.isPortrait ? display.activeAngle : 0
        statusItem?.button?.image = FlipNinjaMenuBarIcon.image(angle: angle)
    }

    private func refreshMenus() {
        portraitMenuItem?.title = display.isPortrait
            ? "Back to Landscape"
            : "Portrait Mode (Ctrl+Fn+O)"
        let currentAngle = display.isPortrait ? display.activeAngle : 0
        portraitMenuItem?.image = FlipNinjaMenuBarIcon.image(angle: currentAngle, length: 14)
        portraitMenuItem?.state = display.isPortrait ? .on : .off
        portraitMenuItem?.isEnabled = display.rotationAvailable

        for item in angleSubmenu?.items ?? [] {
            item.state = (item.representedObject as? Int) == display.portraitAngle.rawValue
                ? .on
                : .off
        }

        remapMenuItem?.state = settings.scrollRotation ? .on : .off
        launchAtLoginMenuItem?.state = launchAtLogin.isEnabled ? .on : .off
    }

    // MARK: - Popover

    private func setupPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 440)

        let hosting = NSHostingController(
            rootView: MainPopoverView(
                display: display,
                settings: settings,
                launchAtLogin: launchAtLogin,
                updater: updater,
                onClose: { [weak self] in self?.closePopover() },
                onTogglePortrait: { [weak self] in self?.togglePortrait() },
                onRequestAccessibility: { [weak self] in self?.requestAccessibility() },
                onRetryEventTap: { [weak self] in self?.retryEventTap() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        popover.contentViewController = hosting
        self.popover = popover
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let statusItem else { return }

        // Accessibility clients (and VoiceOver) trigger the action without a
        // mouse event; treat that as a normal click.
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp

        if isRightClick {
            launchAtLogin.refresh()
            settings.refreshAccessibility()
            refreshMenus()
            statusItem.menu = rightClickMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover?.isShown == true {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, let popover else { return }

        launchAtLogin.refresh()
        settings.refreshAccessibility()
        refreshMenus()
        updatePopoverSize(for: popover)

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    private func updatePopoverSize(for popover: NSPopover) {
        guard let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        guard fitting.height > 0 else { return }
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let height = min(max(fitting.height, 320), screenHeight - 80)
        popover.contentSize = NSSize(width: 320, height: height)
    }

    // MARK: - Actions

    private func togglePortrait() {
        // The menu bar moves to another screen edge when the display rotates;
        // an open popover would be left floating at the old position.
        closePopover()
        display.toggle()
    }

    @objc private func togglePortraitFromMenu() {
        togglePortrait()
    }

    @objc private func selectAngleFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let angle = PortraitAngle(rawValue: raw) else {
            return
        }
        closePopover()
        display.selectPortraitAngle(angle)
    }

    @objc private func toggleRemapFromMenu() {
        settings.scrollRotation.toggle()
    }

    @objc private func toggleLaunchAtLoginFromMenu() {
        launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
        refreshMenus()
    }

    @objc private func checkForUpdatesFromMenu() {
        updater.checkForUpdatesPresentingAlert()
    }

    @objc private func showPopoverFromMenu() {
        showPopover()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Accessibility

    private func startEventTapIfPossible() {
        settings.refreshAccessibility()

        guard settings.accessibilityGranted else {
            settings.setEventTapActive(false)
            startPermissionPolling()
            return
        }

        if eventTap.start() {
            settings.setEventTapActive(true)
            stopPermissionPolling()
        } else {
            settings.setEventTapActive(false)
            startPermissionPolling()
            if !didShowTapFailure {
                didShowTapFailure = true
                presentEventTapFailure()
            }
        }

        applyInputConfiguration()
        refreshMenus()
    }

    private func requestAccessibility() {
        AccessibilityPermission.requestPrompt()
        AccessibilityPermission.openSettings()
        settings.refreshAccessibility()
        startEventTapIfPossible()
    }

    /// Rebuilds the taps after a permission change without relaunching the app.
    private func retryEventTap() {
        eventTap.stop()
        settings.setEventTapActive(false)
        startEventTapIfPossible()
    }

    private func recheckPermissions() {
        settings.refreshAccessibility()
        if settings.accessibilityGranted, !settings.eventTapActive {
            startEventTapIfPossible()
        }
        refreshMenus()
    }

    private func startPermissionPolling() {
        guard permissionTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recheckPermissions()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    // MARK: - Alerts

    private func showOnboardingIfNeeded() {
        guard !settings.hasCompletedOnboarding else { return }
        settings.hasCompletedOnboarding = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Welcome to FlipNinja"

        var details = """
        FlipNinja rotates your main display for vertical use and rotates trackpad scrolling to match.

        • Accessibility access is required for the Control + Fn + O shortcut and scroll rotation.
        """
        if AccessibilityPermission.globeKeyOpensEmoji {
            details += """

            • Your Globe (Fn) key currently opens Emoji & Symbols. Set “Press Globe key to” → “Do Nothing” in Keyboard settings for a clean shortcut.
            """
        }
        alert.informativeText = details
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            requestAccessibility()
        }
    }

    private func presentRotationError(_ message: String) {
        closePopover()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't rotate the display"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentEventTapFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't start input remapping"
        alert.informativeText = """
        FlipNinja could not create the global event tap. Make sure FlipNinja is \
        enabled in System Settings → Privacy & Security → Accessibility, then \
        try again.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            requestAccessibility()
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.1"
    }
}
