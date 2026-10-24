import Combine
import Foundation

/// Persisted preferences plus a few transient status flags the popover shows.
@MainActor
final class AppSettings: ObservableObject {

    /// Rotates trackpad/Accelerometer-free scrolling with the display.
    /// The defaults key keeps the historical name so existing installs
    /// migrate without a reset.
    @Published var scrollRotation: Bool {
        didSet { defaults.set(scrollRotation, forKey: Keys.rotateScrolling) }
    }

    @Published private(set) var accessibilityGranted = false
    @Published private(set) var eventTapActive = false

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let rotateScrolling = "rotateScrolling"
        static let legacyRemapTrackpad = "remapTrackpad"
        static let onboarding = "hasCompletedOnboarding"
    }

    init() {
        let stored = defaults.object(forKey: Keys.rotateScrolling) as? Bool
        let legacy = defaults.object(forKey: Keys.legacyRemapTrackpad) as? Bool
        scrollRotation = stored ?? legacy ?? true
        accessibilityGranted = AccessibilityPermission.isTrusted
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Keys.onboarding) }
        set { defaults.set(newValue, forKey: Keys.onboarding) }
    }

    func refreshAccessibility() {
        accessibilityGranted = AccessibilityPermission.isTrusted
    }

    func setEventTapActive(_ active: Bool) {
        eventTapActive = active
    }
}
