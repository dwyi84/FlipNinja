import AppKit
import ApplicationServices
import Foundation

/// Accessibility (TCC) helpers for the global event tap.
enum AccessibilityPermission {

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt. The app must already be a signed bundle for
    /// the permission to stick across launches.
    @discardableResult
    static func requestPrompt() -> Bool {
        // kAXTrustedCheckOptionPrompt is a mutable global under Swift 6; the
        // dictionary key is stable and documented.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }



    /// `2` means the Globe key currently opens Emoji & Symbols, which can
    /// interfere with the `Control + Fn + O` shortcut.
    static var globeKeyUsageType: Int? {
        CFPreferencesCopyAppValue(
            "AppleFnUsageType" as CFString,
            "com.apple.HIToolbox" as CFString
        ) as? Int
    }

    static var globeKeyOpensEmoji: Bool {
        globeKeyUsageType == 2
    }

}
