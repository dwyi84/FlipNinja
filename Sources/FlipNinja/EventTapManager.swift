import AppKit
import CoreGraphics
import Foundation

/// Owns two session-level event taps:
///
/// 1. A keyboard tap consumes `Fn(Globe) + Control + O`.
/// 2. A scroll tap rotates continuous scrolling (trackpads and Magic
///    devices) with the display. Continuous events are processed at this
///    level where `scrollWheelEventIsContinuous` and delivery are reliable;
///    physical wheel mice report zero and pass through untouched. Cursor
///    movement from the built-in trackpad is applied by the window server
///    before taps run and cannot be intercepted, so it is left untouched.
///
/// Both taps need only Accessibility and share one dedicated thread and
/// run loop. Only `Configuration` crosses threads, guarded by a lock.
final class EventTapManager: @unchecked Sendable {

    struct Configuration: Sendable {
        var isPortrait = false
        var rotation = PortraitAngle.usbOnBottom.rawValue
        var scrollEnabled = true
    }

    private static let shortcutKeyCode: Int64 = 31 // kVK_ANSI_O

    private let lock = NSLock()
    private let onHotKey: @Sendable () -> Void

    private var configuration = Configuration()
    private var taps: [CFMachPort] = []
    private var sources: [CFRunLoopSource] = []
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    /// State only touched from the tap thread.
    private var fnIsDown = false
    private var pendingHotKeyRelease = false
    private var lastScrollTrace = Date.distantPast

    init(onHotKey: @escaping @Sendable () -> Void) {
        self.onHotKey = onHotKey
    }

    // MARK: Lifecycle

    func update(isPortrait: Bool, rotation: Int, scrollEnabled: Bool) {
        lock.withLock {
            configuration = Configuration(
                isPortrait: isPortrait,
                rotation: rotation,
                scrollEnabled: scrollEnabled
            )
        }
    }

    @discardableResult
    func start() -> Bool {
        let alreadyRunning = lock.withLock { !taps.isEmpty }
        guard !alreadyRunning else { return true }

        let keyboardMask = Self.mask(for: [.keyDown, .keyUp, .flagsChanged])
        let scrollMask = Self.mask(for: [.scrollWheel])

        var created: [CFMachPort] = []

        if let keyboard = createTap(at: .cgSessionEventTap, mask: keyboardMask) {
            created.append(keyboard)
        }
        if let scroll = createTap(at: .cgSessionEventTap, mask: scrollMask) {
            created.append(scroll)
        }

        guard !created.isEmpty else { return false }
        lock.withLock { taps = created }

        let thread = Thread { [weak self] in
            guard let self else { return }
            let taps = self.lock.withLock { self.taps }
            guard !taps.isEmpty else { return }

            let runLoop = CFRunLoopGetCurrent()
            var sources: [CFRunLoopSource] = []
            for tap in taps {
                guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                    continue
                }
                CFRunLoopAddSource(runLoop, source, .commonModes)
                sources.append(source)
            }
            self.lock.withLock {
                self.runLoop = runLoop
                self.sources = sources
            }
            for tap in taps {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            CFRunLoopRun()
        }
        thread.name = "FlipNinja.EventTap"
        thread.qualityOfService = .userInteractive
        lock.withLock { self.thread = thread }
        thread.start()

        return true
    }

    func stop() {
        let (taps, runLoop) = lock.withLock { (self.taps, self.runLoop) }
        for tap in taps {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        for tap in taps {
            CFMachPortInvalidate(tap)
        }
        lock.withLock {
            self.taps = []
            self.sources = []
            self.runLoop = nil
            self.thread = nil
        }
    }

    private static func mask(for types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
    }

    private func createTap(at location: CGEventTapLocation, mask: CGEventMask) -> CFMachPort? {
        let level = location == .cghidEventTap ? "HID" : "session"
        guard let tap = CGEvent.tapCreate(
            tap: location,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: flipNinjaEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("FlipNinja: \(level) tap unavailable")
            return nil
        }
        NSLog("FlipNinja: event tap installed at \(level) level")
        return tap
    }

    // MARK: Event handling (tap thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            for tap in lock.withLock({ self.taps }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            fnIsDown = event.flags.contains(.maskSecondaryFn)
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.shortcutKeyCode {
                NSLog("FlipNinja: keyDown keycode=\(keyCode) flags=0x\(String(event.flags.rawValue, radix: 16))")
            }
            guard keyCode == Self.shortcutKeyCode else {
                return Unmanaged.passUnretained(event)
            }

            if isShortcut(event) {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat {
                    pendingHotKeyRelease = true
                    NSLog("FlipNinja: hotkey fired")
                    onHotKey()
                }
                // Consume the shortcut and every auto-repeat while held.
                return nil
            }

            if pendingHotKeyRelease {
                // If the matching key-up was lost (tap re-enabled, app
                // switched), do not swallow a normal O keystroke forever.
                if isShortcut(event) {
                    return nil
                }
                pendingHotKeyRelease = false
            }
            return Unmanaged.passUnretained(event)

        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.shortcutKeyCode, pendingHotKeyRelease {
                pendingHotKeyRelease = false
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .scrollWheel:
            return remappedScroll(event)

        case .mouseMoved:
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func isShortcut(_ event: CGEvent) -> Bool {
        let flags = event.flags
        let control = flags.contains(.maskControl)
        let function = flags.contains(.maskSecondaryFn) || fnIsDown
        return control && function
    }

    private func snapshot() -> Configuration {
        lock.withLock { configuration }
    }

    private func remappedScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let config = snapshot()
        guard config.isPortrait, config.scrollEnabled else {
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1 else {
            return Unmanaged.passUnretained(event)
        }
        let now = Date()
        if now.timeIntervalSince(lastScrollTrace) > 2 {
            lastScrollTrace = now
            NSLog("FlipNinja: continuous scroll v=\(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) h=\(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) rot=\(config.rotation)")
        }
        // Continuous events come from trackpads and Magic devices; wheel mice
        // report 0 and pass through untouched.
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1 else {
            return Unmanaged.passUnretained(event)
        }
        // CoreGraphics keeps the line, point, and fixed-point representations
        // of a scroll event in sync, so every pair must be read before any
        // pair is written. Otherwise the second write would map an
        // already-derived value.
        let delta = mappedScrollPair(
            vertical: .scrollWheelEventDeltaAxis1,
            horizontal: .scrollWheelEventDeltaAxis2,
            rotation: config.rotation,
            event: event
        )
        let point = mappedScrollPair(
            vertical: .scrollWheelEventPointDeltaAxis1,
            horizontal: .scrollWheelEventPointDeltaAxis2,
            rotation: config.rotation,
            event: event
        )
        let fixedPoint = mappedScrollPair(
            vertical: .scrollWheelEventFixedPtDeltaAxis1,
            horizontal: .scrollWheelEventFixedPtDeltaAxis2,
            rotation: config.rotation,
            event: event
        )

        if let delta {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: delta.vertical)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: delta.horizontal)
        }
        if let point {
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: point.vertical)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: point.horizontal)
        }
        if let fixedPoint {
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixedPoint.vertical)
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixedPoint.horizontal)
        }

        return Unmanaged.passUnretained(event)
    }

    private func mappedScrollPair(
        vertical: CGEventField,
        horizontal: CGEventField,
        rotation: Int,
        event: CGEvent
    ) -> (vertical: Int64, horizontal: Int64)? {
        let oldVertical = event.getIntegerValueField(vertical)
        let oldHorizontal = event.getIntegerValueField(horizontal)
        guard oldVertical != 0 || oldHorizontal != 0 else { return nil }
        return InputTransform.scrollDeltas(
            vertical: oldVertical,
            horizontal: oldHorizontal,
            rotation: rotation
        )
    }

}

// MARK: - C callback

private func flipNinjaEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handle(type: type, event: event)
}
