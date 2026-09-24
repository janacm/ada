import Foundation

/// Whether the snooze options start expanded ("pinned open") on every alert.
///
/// The alert page is a fresh `file://` load in a fresh helper process each
/// time, so the page cannot remember the choice itself. Instead the helper
/// reads it from user defaults and injects it before the page's own script
/// runs (`bootstrapScript`), and the page posts changes back through the
/// `adaSnoozePin` message handler (`pinned(fromMessageBody:)`).
public enum SnoozePreference {
    /// `~/Library/Preferences/com.ada.alert.plist`. A named suite rather than
    /// `UserDefaults.standard`, because an unbundled SwiftPM executable has no
    /// bundle id to key the standard domain on.
    public static let suiteName = "com.ada.alert"
    public static let pinnedKey = "snoozePinned"
    public static let messageHandlerName = "adaSnoozePin"

    public static func isPinned(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: pinnedKey)
    }

    public static func setPinned(_ pinned: Bool, in defaults: UserDefaults) {
        defaults.set(pinned, forKey: pinnedKey)
    }

    /// The pin state an `adaSnoozePin` message asks for, or nil when the body
    /// is not a boolean. The page posts a JS `true`/`false`, which arrives as a
    /// boolean `NSNumber`; any other number, a string or null is ignored rather
    /// than coerced, so a malformed post never flips the stored preference.
    public static func pinned(fromMessageBody body: Any) -> Bool? {
        if let number = body as? NSNumber {
            guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        return body as? Bool
    }

    /// Runs at document start, ahead of alert.html's own script.
    public static func bootstrapScript(pinned: Bool) -> String {
        "window.adaPrefs = Object.assign(window.adaPrefs || {}, { snoozePinned: \(pinned) });"
    }
}
