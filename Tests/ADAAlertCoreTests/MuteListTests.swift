import Foundation
import Testing
@testable import ADAAlertCore

// Reading the mute markers the way lib/ada-mute.sh does. test/ada-mute.bats
// pins the shell's side; these pin that the menu bar agrees with it.
@Suite struct MuteListTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func marker(_ dir: URL, _ key: String, label: String = "", age: TimeInterval) throws {
        let url = dir.appendingPathComponent(key)
        try label.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    @Test func listsMarkersNewestFirstWithTheirLabels() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try marker(dir, "claude-old", label: "fix the flaky test\n", age: 7200)
        try marker(dir, "zsh-1-2", age: 60)
        let muted = MuteList.read(directory: dir, maxAge: 86400, now: now)
        #expect(muted.map(\.key) == ["zsh-1-2", "claude-old"])
        #expect(muted[1].label == "fix the flaky test")
        #expect(muted[1].kind == "Claude Code conversation")
        #expect(muted[0].label == nil)
        #expect(muted[0].kind == "terminal")
    }

    @Test func anEmptyMarkerFallsBackToTheHistoryLabel() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try marker(dir, "opencode-s1", age: 10)
        let history = AlertHistory.parse(
            ["1", "1789999000", "shown", "0", "opencode-s1", "session", "refactor the parser", "", "0", "", "", "", ""]
                .joined(separator: "\t"))
        let muted = MuteList.read(directory: dir, maxAge: 86400, now: now, history: history)
        #expect(muted.first?.label == "refactor the parser")
        #expect(muted.first?.kind == "opencode session")
    }

    // The shell: muted while now - mtime <= max.
    @Test func aMuteLastsExactlyMaxAgeSeconds() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try marker(dir, "paseo-at", age: 60)
        try marker(dir, "paseo-over", age: 61)
        #expect(MuteList.read(directory: dir, maxAge: 60, now: now).map(\.key) == ["paseo-at"])
        #expect(MuteList.read(directory: dir, maxAge: nil, now: now).count == 2)
    }

    @Test func onlyPlainFilesWithValidNamesAreMarkers() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try marker(dir, "claude-real", age: 1)
        try marker(dir, ".hidden", age: 1)
        try marker(dir, "-flag", age: 1)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("claude-dir"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("claude-link"),
                                                   withDestinationURL: dir.appendingPathComponent("claude-real"))
        #expect(MuteList.read(directory: dir, maxAge: 86400, now: now).map(\.key) == ["claude-real"])
        #expect(MuteList.read(directory: dir.appendingPathComponent("missing"), maxAge: 86400, now: now).isEmpty)
    }

    @Test(arguments: [
        ("claude-6b1a216c", true), ("zsh-123-1790000000", true), ("a", true),
        ("", false), (".x", false), ("-x", false), ("a/b", false), ("../x", false), ("has space", false), ("é", false),
    ])
    func keyRule(_ key: String, _ valid: Bool) {
        #expect(MuteList.isValidKey(key) == valid)
    }

    @Test func keysAreAtMost200Characters() {
        #expect(MuteList.isValidKey(String(repeating: "a", count: 200)))
        #expect(!MuteList.isValidKey(String(repeating: "a", count: 201)))
    }

    @Test func maxAgeFollowsTheShellRule() {
        #expect(MuteList.maxAge(environment: [:]) == 86400)
        #expect(MuteList.maxAge(environment: ["ADA_MUTE_MAX_AGE": "60"]) == 60)
        #expect(MuteList.maxAge(environment: ["ADA_MUTE_MAX_AGE": "0"]) == nil)
        #expect(MuteList.maxAge(environment: ["ADA_MUTE_MAX_AGE": "086400"]) == 86400)
        #expect(MuteList.maxAge(environment: ["ADA_MUTE_MAX_AGE": "soon"]) == 86400)
        #expect(MuteList.maxAge(environment: ["ADA_MUTE_MAX_AGE": "1234567890123456"]) == 86400)
    }
}
