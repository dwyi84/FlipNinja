import AppKit
import CoreGraphics
import Foundation

// MARK: - Portrait angles

/// The two supported vertical orientations. The raw value is the display
/// rotation in degrees.
enum PortraitAngle: Int, CaseIterable, Identifiable {
    /// The USB-C ports on the left edge point down.
    case usbOnBottom = 90
    /// The USB-C ports on the left edge point up.
    case usbOnTop = 270

    var id: Int { rawValue }

    var degrees: Int { rawValue }

    var shortLabel: String { "\(rawValue)°" }

    var label: String {
        switch self {
        case .usbOnTop: "270° — USB-C on Top"
        case .usbOnBottom: "90° — USB-C on Bottom"
        }
    }

    var detail: String {
        switch self {
        case .usbOnTop: "Left-edge ports face up."
        case .usbOnBottom: "Left-edge ports face down."
        }
    }
}

// MARK: - Private display rotation bridge

/// `SLSSetDisplayRotation` superseded `CGSSetDisplayRotation` in recent macOS
/// releases. Both live in SkyLight and share the same C signature, so the
/// symbol is resolved at runtime with a graceful fallback.
private enum DisplayRotationBridge {
    private typealias SetRotationFunction = @convention(c) (UInt32, UInt32) -> Int32

    private struct Resolved {
        let function: SetRotationFunction
        /// `SLSSetDisplayRotation` (macOS 26+) takes degrees; the legacy
        /// `CGSSetDisplayRotation` takes 0–3 quarter-turn indices.
        let usesDegrees: Bool
    }

    private static let resolved: Resolved? = {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        if let symbol = dlsym(handle, "SLSSetDisplayRotation") {
            return Resolved(
                function: unsafeBitCast(symbol, to: SetRotationFunction.self),
                usesDegrees: true
            )
        }
        if let symbol = dlsym(handle, "CGSSetDisplayRotation") {
            return Resolved(
                function: unsafeBitCast(symbol, to: SetRotationFunction.self),
                usesDegrees: false
            )
        }
        return nil
    }()

    static var isAvailable: Bool { resolved != nil }

    /// Returns `nil` when the private API is unavailable.
    static func set(display: CGDirectDisplayID, degrees: Int) -> Int32? {
        guard let resolved else { return nil }
        let value = resolved.usesDegrees ? degrees : degrees / 90
        return resolved.function(display, UInt32(value))
    }
}

// MARK: - DisplayManager

/// Owns the main display's rotation state, persists the preferred portrait
/// angle, and keeps the event tap configuration in sync through `onStateChange`.
@MainActor
final class DisplayManager: ObservableObject {

    @Published private(set) var isPortrait = false
    @Published private(set) var activeAngle = 0
    @Published private(set) var portraitAngle: PortraitAngle
    @Published private(set) var rotationAvailable = DisplayRotationBridge.isAvailable

    /// Called whenever the rotation state or preferred angle changes.
    var onStateChange: (() -> Void)?
    /// Called with a user-facing message when a rotation request fails.
    var onError: ((String) -> Void)?

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let portraitAngle = "portraitAngle"
    }

    private var pendingRotation: Int?
    private var verificationTimer: Timer?

    init() {
        let stored = defaults.object(forKey: Keys.portraitAngle) as? Int
        portraitAngle = PortraitAngle(rawValue: stored ?? PortraitAngle.usbOnBottom.rawValue)
            ?? .usbOnBottom
        syncFromSystem(notify: false)
    }

    // MARK: Public state

    /// Human-readable status for the popover and menu.
    var statusTitle: String {
        isPortrait ? "Portrait \(activeAngle)°" : "Landscape"
    }

    var statusDetail: String {
        if isPortrait {
            return "Trackpad input follows the rotated screen."
        }
        return "Standard horizontal orientation."
    }

    /// The angle used when toggling back into portrait.
    var preferredAngle: Int { portraitAngle.rawValue }

    // MARK: Commands

    func toggle() {
        if isPortrait {
            apply(rotation: 0)
        } else {
            apply(rotation: portraitAngle.rawValue)
        }
    }

    func setPortrait(_ portrait: Bool) {
        if portrait {
            guard !isPortrait else { return }
            apply(rotation: portraitAngle.rawValue)
        } else {
            guard isPortrait else { return }
            apply(rotation: 0)
        }
    }

    func selectPortraitAngle(_ angle: PortraitAngle) {
        portraitAngle = angle
        defaults.set(angle.rawValue, forKey: Keys.portraitAngle)

        if isPortrait {
            apply(rotation: angle.rawValue)
        } else {
            onStateChange?()
        }
    }

    /// Returns the screen to landscape when the app quits.
    func restoreLandscape() {
        guard isPortrait else { return }
        apply(rotation: 0, notify: false)
    }

    // MARK: System synchronisation

    /// Mirrors the display's actual rotation. Used at launch and after screen
    /// reconfiguration or wake; it never forces a rotation by itself.
    func syncFromSystem(notify: Bool = true) {
        // The window server reconfigures screens asynchronously; a read in the
        // middle of our own rotation would briefly report the old angle.
        guard pendingRotation == nil else { return }

        rotationAvailable = DisplayRotationBridge.isAvailable
        let degrees = Int(CGDisplayRotation(CGMainDisplayID()).rounded())
        activeAngle = degrees

        let portrait = degrees == 90 || degrees == 270
        isPortrait = portrait

        if portrait, let angle = PortraitAngle(rawValue: degrees) {
            portraitAngle = angle
            defaults.set(angle.rawValue, forKey: Keys.portraitAngle)
        }

        if notify {
            onStateChange?()
        }
    }

    // MARK: Rotation

    private func apply(rotation: Int, notify: Bool = true) {
        let display = CGMainDisplayID()

        guard let result = DisplayRotationBridge.set(display: display, degrees: rotation) else {
            fail("This macOS version does not expose the private display-rotation API.")
            return
        }
        guard result == 0 else {
            fail("The window server rejected the rotation request (error \(result)).")
            syncFromSystem(notify: notify)
            return
        }

        // `SLSSetDisplayRotation` returns before the framebuffer has actually
        // been rebuilt. Update optimistically, then confirm by polling.
        pendingRotation = rotation
        updateState(degrees: rotation, notify: notify)
        verifyRotation(display: display, expected: rotation)
    }

    private func updateState(degrees: Int, notify: Bool) {
        activeAngle = degrees
        isPortrait = degrees == 90 || degrees == 270
        if isPortrait, let angle = PortraitAngle(rawValue: degrees) {
            portraitAngle = angle
            defaults.set(angle.rawValue, forKey: Keys.portraitAngle)
        }
        if notify {
            onStateChange?()
        }
    }

    private func verifyRotation(display: CGDirectDisplayID, expected: Int) {
        verificationTimer?.invalidate()

        let deadline = Date().addingTimeInterval(3.0)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleVerificationTick(
                    display: display,
                    expected: expected,
                    deadline: deadline
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        verificationTimer = timer
    }

    private func handleVerificationTick(
        display: CGDirectDisplayID,
        expected: Int,
        deadline: Date
    ) {
        let actual = Int(CGDisplayRotation(display).rounded())
        if actual == expected {
            verificationTimer?.invalidate()
            verificationTimer = nil
            pendingRotation = nil
            updateState(degrees: actual, notify: true)
            warpCursor()
        } else if Date() >= deadline {
            verificationTimer?.invalidate()
            verificationTimer = nil
            pendingRotation = nil
            fail("The display reported \(actual)° after requesting \(expected)°.")
            syncFromSystem(notify: true)
        }
    }

    /// The cursor can end up on a part of the desktop that no longer exists
    /// after the framebuffer is rebuilt.
    private func warpCursor() {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
    }

    private func fail(_ message: String) {
        onError?(message)
    }
}
