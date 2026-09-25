import Foundation
import Testing
@testable import ADAAlertCore

// The menu bar's non-AppKit decisions: where its state lives, what its
// children inherit, when to relaunch, one instance, and the setup handoff.
@Suite struct MenuBarSupportTests {
    @Test func statePathsFollowTMPDIRThenTheDarwinDirThenTmp() {
        #expect(StatePaths.resolve(environment: ["TMPDIR": "/t/"], darwinTempDirectory: { "/d/" }).pauseFile.path == "/t/ada-paused")
        #expect(StatePaths.resolve(environment: ["TMPDIR": ""], darwinTempDirectory: { "/d/" }).pauseFile.path == "/d/ada-paused")
        #expect(StatePaths.resolve(environment: [:], darwinTempDirectory: { nil }).pauseFile.path == "/tmp/ada-paused")
        let paths = StatePaths.resolve(environment: ["TMPDIR": "/t"], darwinTempDirectory: { nil })
        #expect(paths.historyFile.path == "/t/ada-history.tsv")
        #expect(paths.muteDirectory.path == "/t/ada-muted")
        #expect(paths.lockFile.path == "/t/ada-menubar.lock")
    }

    @Test func statePathsHonorTheScriptsOverrides() {
        let paths = StatePaths.resolve(environment: [
            "TMPDIR": "/t", "ADA_PAUSE_FILE": "/p", "ADA_HISTORY_FILE": "/h", "ADA_MUTE_DIR": "/m",
        ], darwinTempDirectory: { nil })
        #expect(paths.pauseFile.path == "/p")
        #expect(paths.historyFile.path == "/h")
        #expect(paths.muteDirectory.path == "/m")
    }

    @Test func theRealDarwinTempDirIsAnAbsolutePath() throws {
        let dir = try #require(StatePaths.darwinUserTempDirectory())
        #expect(dir.hasPrefix("/"))
    }

    @Test func commandLine() {
        #expect(MenuBarCommand.parse([]) == .run)
        #expect(MenuBarCommand.parse(["--check"]) == .check)
        #expect(MenuBarCommand.parse(["--print-menu"]) == .printMenu)
        #expect(MenuBarCommand.parse(["-h"]) == .help)
        #expect(MenuBarCommand.parse(["--frob", "x"]) == .unknown("--frob x"))
    }

    @Test func childrenGetTheStateDirAndAPath() {
        let paths = StatePaths.resolve(environment: [:], darwinTempDirectory: { "/d" })
        let bare = ChildEnvironment.make(base: [:], paths: paths)
        #expect(bare["TMPDIR"] == "/d")
        #expect(bare["PATH"] == ChildEnvironment.fallbackPath)
        let kept = ChildEnvironment.make(base: ["TMPDIR": "/mine", "PATH": "/bin"], paths: paths, extra: ["X": "1"])
        #expect(kept["TMPDIR"] == "/mine")
        #expect(kept["PATH"] == "/bin")
        #expect(kept["X"] == "1")
    }

    @Test func relaunchWhenTheBinaryIsReplacedExitWhenItStaysGone() {
        let original = ExecutableIdentity(device: 1, inode: 10)
        var watcher = RelaunchWatcher(original: original)
        #expect(watcher.check(original) == .keepRunning)
        #expect(watcher.check(ExecutableIdentity(device: 1, inode: 11)) == .relaunch)
        // An upgrade swaps the opt symlink: one missing tick is tolerated.
        #expect(watcher.check(nil) == .keepRunning)
        #expect(watcher.check(original) == .keepRunning)
        #expect(watcher.check(nil) == .keepRunning)
        #expect(watcher.check(nil) == .exit)
    }

    @Test func identityChangesWhenAFileIsReplacedByRename() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("ada-menubar")
        try "old".write(to: binary, atomically: false, encoding: .utf8)
        let before = try #require(ExecutableIdentity.of(path: binary.path))
        let replacement = dir.appendingPathComponent("ada-menubar.new")
        try "new".write(to: replacement, atomically: false, encoding: .utf8)
        _ = rename(replacement.path, binary.path)
        #expect(ExecutableIdentity.of(path: binary.path) != before)
        #expect(ExecutableIdentity.of(path: dir.appendingPathComponent("missing").path) == nil)
    }

    @Test func launchdStartedMeansOurLabel() {
        #expect(RelaunchWatcher.launchedByLaunchd(environment: ["XPC_SERVICE_NAME": "com.ada.menubar"]))
        #expect(!RelaunchWatcher.launchedByLaunchd(environment: ["XPC_SERVICE_NAME": "0"]))
        #expect(!RelaunchWatcher.launchedByLaunchd(environment: [:]))
    }

    // flock belongs to the open file description, so a second open in the same
    // process conflicts just as a second process would.
    @Test func aSecondInstanceFindsTheLockHeld() throws {
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: lock) }
        guard case let .acquired(first) = SingleInstanceLock.acquire(at: lock) else {
            Issue.record("first acquire failed"); return
        }
        guard case .heldElsewhere = SingleInstanceLock.acquire(at: lock) else {
            Issue.record("second acquire should find the lock held"); return
        }
        _ = first
        withExtendedLifetime(first) {}
    }

    @Test func aLockReleasedByItsHolderCanBeTaken() throws {
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: lock) }
        do {
            guard case .acquired = SingleInstanceLock.acquire(at: lock) else { Issue.record("acquire"); return }
        }
        guard case .acquired = SingleInstanceLock.acquire(at: lock) else {
            Issue.record("a released lock should be free"); return
        }
    }

    @Test func anUnopenableLockLetsTheMenuBarRun() {
        guard case .unavailable = SingleInstanceLock.acquire(at: URL(fileURLWithPath: "/nonexistent-dir/ada.lock")) else {
            Issue.record("expected unavailable"); return
        }
    }

    @Test func setupRunsTheInstallDirsInstallerElseTheStagesSource() {
        let install = URL(fileURLWithPath: "/opt/homebrew/opt/ada/libexec")
        let stage = StageInfo.parse("source=/Users/me/Documents/ada\n")
        #expect(SetupCommand.installerPath(installDirectory: install, stageInfo: stage, fileExists: { _ in true })
                == "/opt/homebrew/opt/ada/libexec/ada-install.sh")
        #expect(SetupCommand.installerPath(installDirectory: install, stageInfo: stage, fileExists: { _ in false })
                == "/Users/me/Documents/ada/ada-install.sh")
        #expect(SetupCommand.installerPath(installDirectory: install, stageInfo: nil, fileExists: { _ in false }) == nil)
    }

    @Test func setupScriptQuotesThePath() {
        #expect(SetupCommand.shellQuote("/a b/it's") == "'/a b/it'\\''s'")
        let script = SetupCommand.script(installer: "/x y/ada-install.sh")
        #expect(script.hasPrefix("#!/bin/bash\n"))
        #expect(script.contains("exec '/x y/ada-install.sh'\n"))
    }

    @Test func integrationStatusParsesTheReport() {
        let rows = IntegrationStatus.parse("""
        terminal\tok\tTerminal commands\t~/.zshrc sources /x/ada.sh
        paseo\tbrand-new\tPaseo\tsomething new
        short\tline
        claude\toff\tClaude Code\tdetail\twith a tab
        """)
        #expect(rows.count == 3)
        #expect(rows[0] == IntegrationStatus(id: "terminal", state: .ok, name: "Terminal commands", detail: "~/.zshrc sources /x/ada.sh"))
        #expect(rows[1].state == .warn)
        #expect(rows[2].detail == "detail\twith a tab")
    }

    @Test func stageInfoParses() {
        let info = StageInfo.parse("source=/src/ada\nrev=abc1234\ndirty=1\nstaged_at=1790000000\nby=ada-menubar\n")
        #expect(info.source == "/src/ada")
        #expect(info.rev == "abc1234")
        #expect(info.dirty)
        #expect(info.stagedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(info.stagedBy == "ada-menubar")
        #expect(StageInfo.parse("rev=\n").rev == nil)
    }
}
