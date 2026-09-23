import Foundation
import Testing
@testable import ADAAlertCore

// The http(s)-only guard on the page's adaOpen bridge. Anything this lets
// through goes straight to NSWorkspace.shared.open.
@Suite struct ExternalLinkTests {
    @Test(arguments: [
        "http://example.com/",
        "https://github.com/janacm/ada/issues/new",
        "HTTPS://GitHub.com/janacm/ada",
    ])
    func opensWebLinks(_ link: String) throws {
        let url = try #require(ExternalLink.openableURL(from: link))
        #expect(url.absoluteString == link)
    }

    @Test(arguments: [
        "file:///etc/passwd",
        "javascript:alert(1)",
        "claude://resume?session=abc",
        "mailto:someone@example.com",
        "not a url",               // parses, but has no scheme at all
        "https:",                  // parses as https, but names no host
        "https:///path-only",
    ])
    func refusesEverythingElse(_ link: String) {
        #expect(ExternalLink.openableURL(from: link) == nil)
    }

    // Strings URL(string:) cannot parse on current Foundation.
    @Test(arguments: ["", "http://[::1", "https://exa mple.com"])
    func refusesUnparseableStrings(_ link: String) {
        #expect(ExternalLink.openableURL(from: link) == nil)
    }

    // WKScriptMessage.body is whatever the page posted: a number, an array, a
    // dictionary or null all arrive as Foundation objects, never as a URL.
    @Test func refusesNonStringBodies() {
        #expect(ExternalLink.openableURL(from: 42) == nil)
        #expect(ExternalLink.openableURL(from: ["https://example.com"]) == nil)
        #expect(ExternalLink.openableURL(from: ["url": "https://example.com"]) == nil)
        #expect(ExternalLink.openableURL(from: NSNull()) == nil)
        #expect(ExternalLink.openableURL(from: URL(string: "https://example.com")!) == nil)
    }
}
