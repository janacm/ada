import Foundation
import XCTest
@testable import IYFAlertCore

final class AlertCommandLineTests: XCTestCase {
    func testParsesCheckCommand() throws {
        XCTAssertEqual(try parsed(["--check"]), .check)
    }

    func testParsesHelpCommand() throws {
        XCTAssertEqual(try parsed(["--help"]), .help)
    }

    func testParsesAlertURL() throws {
        XCTAssertEqual(
            try parsed(["file:///tmp/alert.html?cmd=test"]),
            .show(URL(string: "file:///tmp/alert.html?cmd=test")!)
        )
    }

    func testRejectsMissingURL() {
        if case .success = AlertCommandLine.parse([]) {
            XCTFail("Missing URL should fail")
        }
    }

    func testRejectsMalformedURL() {
        if case .success = AlertCommandLine.parse(["not-a-url"]) {
            XCTFail("Malformed URL should fail")
        }
    }

    func testBuildsSignalURLWithDaemonToken() throws {
        let alertURL = URL(string: "file:///tmp/alert.html?sport=47125&stoken=abc123")!
        let baseURL = try XCTUnwrap(AlertSignalURL.baseURL(from: alertURL))
        XCTAssertEqual(AlertSignalURL.signalURL(baseURL: baseURL, path: "focus")?.absoluteString, "http://127.0.0.1:47125/abc123/focus")
        XCTAssertEqual(AlertSignalURL.signalURL(baseURL: baseURL, path: "snooze/5")?.absoluteString, "http://127.0.0.1:47125/abc123/snooze/5")
    }

    func testSignalURLRequiresDaemonQueryParams() {
        XCTAssertNil(AlertSignalURL.baseURL(from: URL(string: "file:///tmp/alert.html")!))
    }

    private func parsed(_ arguments: [String]) throws -> AlertCommand {
        switch AlertCommandLine.parse(arguments) {
        case .success(let command):
            return command
        case .failure(let error):
            throw ParseFailure(message: error.message)
        }
    }
}

private struct ParseFailure: Error {
    let message: String
}
