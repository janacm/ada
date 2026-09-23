import Foundation
import Testing
@testable import ADAAlertCore

// Swift Testing rather than XCTest: the Command Line Tools ship Testing.framework
// but no XCTest, so an XCTest suite does not even compile on a machine without
// Xcode (the setup ada's own installer targets). `swift test` runs these under
// both toolchains.

@Suite struct AlertCommandLineTests {
    @Test func parsesCheckCommand() throws {
        #expect(try parsed(["--check"]) == .check)
    }

    @Test(arguments: ["--help", "-h", "help"])
    func parsesHelpSpellings(_ flag: String) throws {
        #expect(try parsed([flag]) == .help)
    }

    @Test func parsesAlertURL() throws {
        #expect(
            try parsed(["file:///tmp/alert.html?cmd=test"])
                == .show(URL(string: "file:///tmp/alert.html?cmd=test")!)
        )
    }

    @Test func rejectsMissingURL() {
        #expect(failureMessage([]) == AlertCommandLine.usage)
    }

    @Test func rejectsMalformedURL() {
        #expect(failureMessage(["not-a-url"]) == AlertCommandLine.usage)
    }

    // ada-show-alert.sh passes exactly one URL; a second argument means the
    // caller is confused, and guessing which one to show would hide that.
    @Test func rejectsExtraArguments() {
        #expect(failureMessage(["file:///tmp/a.html", "file:///tmp/b.html"]) == AlertCommandLine.usage)
    }

    @Test func usageNamesBothModes() {
        #expect(AlertCommandLine.usage.contains("ada-alert <alert-url>"))
        #expect(AlertCommandLine.usage.contains("ada-alert --check"))
    }

    // The page's window.close() must reach the native side, or the alert's own
    // close button and auto-close would leave an empty borderless window up.
    @Test func closeBridgeRoutesWindowCloseToTheNativeHandler() {
        #expect(nativeCloseBridgeScript.contains("window.adaNative = true"))
        #expect(nativeCloseBridgeScript.contains("messageHandlers.adaClose.postMessage"))
    }

    private func parsed(_ arguments: [String]) throws -> AlertCommand {
        switch AlertCommandLine.parse(arguments) {
        case .success(let command):
            return command
        case .failure(let error):
            throw ParseFailure(message: error.message)
        }
    }

    private func failureMessage(_ arguments: [String]) -> String? {
        if case .failure(let error) = AlertCommandLine.parse(arguments) {
            return error.message
        }
        return nil
    }
}

@Suite struct AlertSignalURLTests {
    @Test func buildsSignalURLWithDaemonToken() throws {
        let alertURL = URL(string: "file:///tmp/alert.html?sport=47125&stoken=abc123")!
        let baseURL = try #require(AlertSignalURL.baseURL(from: alertURL))
        #expect(AlertSignalURL.signalURL(baseURL: baseURL, path: "focus")?.absoluteString == "http://127.0.0.1:47125/abc123/focus")
        #expect(AlertSignalURL.signalURL(baseURL: baseURL, path: "snooze/5")?.absoluteString == "http://127.0.0.1:47125/abc123/snooze/5")
    }

    @Test func signalURLRequiresDaemonQueryParams() {
        #expect(AlertSignalURL.baseURL(from: URL(string: "file:///tmp/alert.html")!) == nil)
    }

    // The launcher only sets sport/stoken when the snooze daemon actually came
    // up. Anything else must mean "no daemon", never a request to a bogus port.
    @Test(arguments: [
        "sport=0&stoken=abc",
        "sport=-1&stoken=abc",
        "sport=port&stoken=abc",
        "sport=47125&stoken=",
        "sport=47125",
    ])
    func rejectsUnusableDaemonParams(_ query: String) {
        #expect(AlertSignalURL.baseURL(from: URL(string: "file:///tmp/alert.html?\(query)")!) == nil)
    }
}

private struct ParseFailure: Error {
    let message: String
}
