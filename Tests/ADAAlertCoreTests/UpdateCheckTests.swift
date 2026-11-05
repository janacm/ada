import Foundation
import Testing
@testable import ADAAlertCore

// The menu bar's read of the update check: the same version rules and files
// as lib/ada-update.sh, which owns the check and every write.
@Suite struct UpdateCheckTests {
    @Test func versionsAreTwoToFourNumbers() {
        for good in ["0.5", "1.2.3", "1.2.3.4", "0.10", "123456.0"] {
            #expect(UpdateCheck.isVersion(good), "\(good)")
        }
        for bad in ["", "0", "1.2.3.4.5", "v0.5", "0.5-", "0..5", "1234567.0", "HEAD-1a2b3c4", "0.５", " 0.5"] {
            #expect(!UpdateCheck.isVersion(bad), "\(bad)")
        }
    }

    @Test func versionsCompareNumberByNumber() {
        #expect(UpdateCheck.isNewer("0.5", than: "0.4"))
        #expect(UpdateCheck.isNewer("0.10", than: "0.9"))
        #expect(UpdateCheck.isNewer("1.0", than: "0.99"))
        #expect(UpdateCheck.isNewer("0.5.1", than: "0.5"))
        #expect(!UpdateCheck.isNewer("0.4", than: "0.5"))
        #expect(!UpdateCheck.isNewer("0.5", than: "0.5"))
        #expect(!UpdateCheck.isNewer("0.5.0", than: "0.5"))
        #expect(!UpdateCheck.isNewer("0.5", than: "0.5.0"))
    }

    @Test func theFilesParseAsTheShellWritesThem() {
        #expect(UpdateCheck.installed(fromVersionFile: "0.4\n") == "0.4")
        #expect(UpdateCheck.installed(fromVersionFile: "HEAD-1a2b3c4\n") == nil)
        #expect(UpdateCheck.installed(fromVersionFile: "") == nil)
        #expect(UpdateCheck.latest(fromCache: "1000 0.5 ok\n") == "0.5")
        #expect(UpdateCheck.latest(fromCache: "1000 0.5 failed\n") == "0.5")
        #expect(UpdateCheck.latest(fromCache: "1000 - failed\n") == nil)
        #expect(UpdateCheck.latest(fromCache: "yesterday 0.5 ok\n") == nil)
        #expect(UpdateCheck.latest(fromCache: "1000\n") == nil)
    }

    @Test func theOffSwitchLivesBesideThePaseoEnvFile() {
        #expect(UpdateCheck.offFile(environment: ["HOME": "/Users/x"]).path == "/Users/x/.local/share/ada/update-check-off")
        #expect(UpdateCheck.offFile(environment: ["HOME": "/Users/x", "ADA_UPDATE_OFF_FILE": "/o"]).path == "/o")
    }

    @Test func theCommandFileRunsBrewFromTheInstallsPrefix() {
        let brew = UpdateCheck.script(installDirectory: URL(fileURLWithPath: "/opt/homebrew/opt/ada/libexec"))
        #expect(brew.contains("'/opt/homebrew/bin/brew' update && '/opt/homebrew/bin/brew' upgrade ada\n"))
        #expect(brew.hasPrefix("#!/bin/bash\n"))
        let other = UpdateCheck.script(installDirectory: URL(fileURLWithPath: "/Users/x/.local/share/ada"))
        #expect(other.contains("\nbrew update && brew upgrade ada\n"))
        #expect(UpdateCheck.command == "brew update && brew upgrade ada")
    }

    @Test func readOffersOnlyANewerReleaseWithChecksOn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ada-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("ada-update")
        let version = dir.appendingPathComponent("VERSION")
        let off = dir.appendingPathComponent("off")
        let environment = ["ADA_UPDATE_OFF_FILE": off.path]
        func read(_ env: [String: String] = environment) -> AvailableUpdate? {
            UpdateCheck.read(cacheAt: cache, installDirectory: dir, environment: env)
        }

        try "1000 0.5 ok\n".write(to: cache, atomically: true, encoding: .utf8)
        #expect(read() == nil)  // no VERSION: a checkout
        try "0.4\n".write(to: version, atomically: true, encoding: .utf8)
        #expect(read() == AvailableUpdate(installed: "0.4", latest: "0.5"))
        #expect(read(environment.merging(["ADA_UPDATE_CHECK": "0"]) { $1 }) == nil)
        try "".write(to: off, atomically: true, encoding: .utf8)
        #expect(read() == nil)
        try FileManager.default.removeItem(at: off)
        try FileManager.default.createSymbolicLink(atPath: off.path, withDestinationPath: dir.appendingPathComponent("nowhere").path)
        #expect(read() == nil)  // a dangling symlink still counts as off
        try FileManager.default.removeItem(at: off)
        try "0.5\n".write(to: version, atomically: true, encoding: .utf8)
        #expect(read() == nil)  // up to date

        // A symlinked cache is not read, as in the shell.
        try "0.4\n".write(to: version, atomically: true, encoding: .utf8)
        let target = dir.appendingPathComponent("target")
        try "1000 0.9 ok\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createSymbolicLink(atPath: cache.path, withDestinationPath: target.path)
        #expect(read() == nil)
    }
}
