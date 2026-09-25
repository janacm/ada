import Foundation
import Testing
@testable import ADAAlertCore

// Reading lib/ada-history.sh's file, and where a click on a Recent Alerts
// entry goes. test/ada-history.bats pins the writer's side of the format.
@Suite struct AlertHistoryTests {
    private func line(_ fields: [String]) -> String {
        fields.joined(separator: "\t")
    }

    private let full = [
        "1", "1790000000", "shown", "0", "claude-abc", "conversation", "make test", "2m 3s", "1",
        "ada", "com.example.term", "Example Term", "claude://resume?session=abc",
    ]

    @Test func parsesEveryColumnOfAVersionOneLine() throws {
        let entry = try #require(AlertHistory.parse(line(full) + "\n").first)
        #expect(entry.date == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(entry.outcome == .shown)
        #expect(entry.snoozed == false)
        #expect(entry.sessionKey == "claude-abc")
        #expect(entry.sessionKind == "conversation")
        #expect(entry.label == "make test")
        #expect(entry.duration == "2m 3s")
        #expect(entry.exitCode == 1)
        #expect(entry.failed)
        #expect(entry.repo == "ada")
        #expect(entry.focusApp == "com.example.term")
        #expect(entry.focusAppName == "Example Term")
        #expect(entry.clickURL == "claude://resume?session=abc")
    }

    @Test func emptyFieldsStayEmptyAndInPlace() throws {
        var fields = full
        fields[4] = ""; fields[9] = ""; fields[12] = ""
        let entry = try #require(AlertHistory.parse(line(fields)).first)
        #expect(entry.sessionKey == "")
        #expect(entry.repo == "")
        #expect(entry.focusApp == "com.example.term")
        #expect(entry.clickURL == "")
    }

    @Test func skipsOtherVersionsShortLinesAndUnknownOutcomes() {
        var v2 = full; v2[0] = "2"
        var odd = full; odd[2] = "exploded"
        let text = [line(v2), "1\t1790000000\tshown", line(odd), "", line(full)].joined(separator: "\n")
        #expect(AlertHistory.parse(text).count == 1)
    }

    @Test func ignoresColumnsANewerWriterAdds() {
        #expect(AlertHistory.parse(line(full + ["future", "columns"])).first?.clickURL == "claude://resume?session=abc")
    }

    @Test func keepsFileOrderOldestFirst() {
        var second = full; second[6] = "second"
        #expect(AlertHistory.parse(line(full) + "\n" + line(second)).map(\.label) == ["make test", "second"])
    }

    @Test func latestLabelForASession() {
        var other = full; other[4] = "claude-other"; other[6] = "elsewhere"
        var newer = full; newer[6] = "newer"
        let entries = AlertHistory.parse([line(full), line(other), line(newer)].joined(separator: "\n"))
        #expect(AlertHistory.latestLabel(forSessionKey: "claude-abc", in: entries) == "newer")
        #expect(AlertHistory.latestLabel(forSessionKey: "claude-none", in: entries) == nil)
    }

    @Test func readsOnlyTheTailOfAHugeFileAndNeverASymlink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ada-history.tsv")
        let lines = (1...50).map { index -> String in
            var fields = full; fields[6] = "alert \(index)"
            return line(fields)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(AlertHistory.read(fileAt: file).count == 50)

        // A tail that starts mid-line drops the partial line.
        let tail = AlertHistory.read(fileAt: file, maxBytes: 300)
        #expect(!tail.isEmpty && tail.count < 50)
        #expect(tail.last?.label == "alert 50")

        let link = dir.appendingPathComponent("link.tsv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(AlertHistory.read(fileAt: link).isEmpty)
        #expect(AlertHistory.read(fileAt: dir.appendingPathComponent("missing")).isEmpty)
    }

    // The daemon's rule: the click URL first, then the app that raised it.
    @Test func clickTargetPrefersTheURL() {
        #expect(ClickTarget.from(clickURL: "claude://resume?session=abc", focusApp: "com.example.term")
                == .url(URL(string: "claude://resume?session=abc")!))
        #expect(ClickTarget.from(clickURL: "", focusApp: "com.mitchellh.ghostty")
                == .application(bundleIdentifier: "com.mitchellh.ghostty"))
        #expect(ClickTarget.from(clickURL: "", focusApp: "") == nil)
    }

    @Test(arguments: ["file:///Applications/Calculator.app", "FILE:///etc/hosts", "not a url", "/just/a/path"])
    func clickTargetRefusesFilesAndNonURLs(_ url: String) {
        #expect(ClickTarget.from(clickURL: url, focusApp: "") == nil)
    }

    @Test(arguments: ["com.example.term", "sh.paseo.desktop", "com.apple.Terminal", "org.x-y.z9"])
    func clickTargetAcceptsBundleIdentifiers(_ id: String) {
        #expect(ClickTarget.from(clickURL: "", focusApp: id) == .application(bundleIdentifier: id))
    }

    @Test(arguments: ["com.example term", "../evil", "com.example;rm", "app/id"])
    func clickTargetRefusesOddBundleIdentifiers(_ id: String) {
        #expect(ClickTarget.from(clickURL: "", focusApp: id) == nil)
    }
}
