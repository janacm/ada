import Foundation
import Testing
@testable import ADAAlertCore

// The "pin snooze options open" preference: what the page's adaSnoozePin posts
// are allowed to store, and the script that hands the stored value back.
@Suite struct SnoozePreferenceTests {
    // A throwaway suite per test, so nothing touches the real com.ada.alert.
    private func scratchDefaults() throws -> UserDefaults {
        let name = "ada-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func unpinnedUntilSomethingIsStored() throws {
        #expect(SnoozePreference.isPinned(in: try scratchDefaults()) == false)
    }

    @Test func storesAndClearsThePin() throws {
        let defaults = try scratchDefaults()
        SnoozePreference.setPinned(true, in: defaults)
        #expect(SnoozePreference.isPinned(in: defaults))
        SnoozePreference.setPinned(false, in: defaults)
        #expect(SnoozePreference.isPinned(in: defaults) == false)
    }

    // A JS boolean arrives in WKScriptMessage.body as a boolean NSNumber.
    @Test func acceptsBooleanBodies() {
        #expect(SnoozePreference.pinned(fromMessageBody: true) == true)
        #expect(SnoozePreference.pinned(fromMessageBody: false) == false)
        #expect(SnoozePreference.pinned(fromMessageBody: NSNumber(value: true)) == true)
        #expect(SnoozePreference.pinned(fromMessageBody: kCFBooleanFalse as Any) == false)
    }

    // Numbers are not coerced: a posted 1 or 0 is a malformed message.
    @Test func ignoresEverythingElse() {
        #expect(SnoozePreference.pinned(fromMessageBody: 1) == nil)
        #expect(SnoozePreference.pinned(fromMessageBody: NSNumber(value: 0)) == nil)
        #expect(SnoozePreference.pinned(fromMessageBody: "true") == nil)
        #expect(SnoozePreference.pinned(fromMessageBody: NSNull()) == nil)
        #expect(SnoozePreference.pinned(fromMessageBody: ["snoozePinned": true]) == nil)
    }

    @Test func bootstrapScriptCarriesTheStoredValue() {
        #expect(SnoozePreference.bootstrapScript(pinned: true).contains("snoozePinned: true"))
        #expect(SnoozePreference.bootstrapScript(pinned: false).contains("snoozePinned: false"))
        #expect(SnoozePreference.bootstrapScript(pinned: true).hasPrefix("window.adaPrefs = "))
    }
}
