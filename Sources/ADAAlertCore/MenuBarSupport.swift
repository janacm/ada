import Foundation

/// What `ada-menubar` was asked to do.
public enum MenuBarCommand: Equatable {
    case run
    case check
    case printMenu
    case help
    case unknown(String)

    public static func parse(_ arguments: [String]) -> MenuBarCommand {
        switch arguments {
        case []: return .run
        case ["--check"]: return .check
        case ["--print-menu"]: return .printMenu
        case ["--help"], ["-h"]: return .help
        default: return .unknown(arguments.joined(separator: " "))
        }
    }

    public static let usage = """
    Usage: ada-menubar [--check | --print-menu | --help]
      (no arguments)  run the ADA menu bar item
      --check         print "ada-menubar native helper ok" and exit
      --print-menu    print the menu as it would open now, and exit
    """
}

/// The environment for the scripts the menu bar runs. Started by launchd it
/// has the plist's PATH; started from Finder it may have almost none, so a
/// missing PATH gets the one the LaunchAgent plists bake in. TMPDIR is set to
/// the directory the menu bar reads its state from, so the scripts write to
/// the same place.
public enum ChildEnvironment {
    public static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public static func make(base: [String: String], paths: StatePaths, extra: [String: String] = [:]) -> [String: String] {
        var environment = base
        if environment["TMPDIR"]?.isEmpty ?? true {
            environment["TMPDIR"] = paths.tempDirectory.path
        }
        if environment["PATH"]?.isEmpty ?? true {
            environment["PATH"] = fallbackPath
        }
        environment.merge(extra) { _, new in new }
        return environment
    }
}

/// The file a running binary was started from, by device and inode, so a
/// replaced binary (a `brew upgrade`, a re-stage) can be told from the old one
/// even though the path is the same.
public struct ExecutableIdentity: Equatable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    /// Follows symlinks: Homebrew's opt path is one, and it is the target that
    /// an upgrade replaces.
    public static func of(path: String) -> ExecutableIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return ExecutableIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

/// Decides, on each tick, whether a menu bar started by launchd should keep
/// running. A `brew upgrade` or a re-stage replaces the binary at the path
/// launchd runs while this process keeps executing the old one; exiting with
/// `relaunchExitCode` makes launchd's KeepAlive start the new one. A binary
/// that is gone for two ticks in a row (a `brew uninstall`) means exit
/// cleanly, which KeepAlive leaves alone; one missing tick is tolerated because
/// an upgrade swaps the opt symlink.
public struct RelaunchWatcher {
    public enum Decision: Equatable {
        case keepRunning, relaunch, exit
    }

    public static let relaunchExitCode: Int32 = 75
    public static let launchdLabel = "com.ada.menubar"

    public let original: ExecutableIdentity
    public private(set) var missingTicks = 0

    public init(original: ExecutableIdentity) {
        self.original = original
    }

    public static func launchedByLaunchd(environment: [String: String]) -> Bool {
        environment["XPC_SERVICE_NAME"] == launchdLabel
    }

    public mutating func check(_ current: ExecutableIdentity?) -> Decision {
        guard let current else {
            missingTicks += 1
            return missingTicks >= 2 ? .exit : .keepRunning
        }
        missingTicks = 0
        return current == original ? .keepRunning : .relaunch
    }
}

/// One menu bar per user: the running one holds an exclusive `flock` on a
/// file in TMPDIR for as long as it lives, and a second one (a login item plus
/// a manual `.build/release/ada-menubar &`) finds it held and exits.
public final class SingleInstanceLock {
    public enum Result {
        case acquired(SingleInstanceLock)
        case heldElsewhere
        /// The lock file can't be opened; run anyway rather than not at all.
        case unavailable
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    public static func acquire(at url: URL) -> Result {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return .unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return .heldElsewhere
        }
        return .acquired(SingleInstanceLock(descriptor: descriptor))
    }
}

/// "Set Up Integrations…" hands the installer to Terminal as a `.command`
/// file, so the installer runs with Terminal's folder access. The menu bar may
/// be a LaunchAgent, which may not run anything under ~/Documents itself.
public enum SetupCommand {
    /// The installer to run: the install directory's own (Homebrew, a checkout
    /// run by hand), else the checkout a stage came from.
    public static func installerPath(installDirectory: URL, stageInfo: StageInfo?, fileExists: (String) -> Bool) -> String? {
        let own = installDirectory.appendingPathComponent("ada-install.sh").path
        if fileExists(own) { return own }
        if let source = stageInfo?.source {
            return URL(fileURLWithPath: source).appendingPathComponent("ada-install.sh").path
        }
        return nil
    }

    public static func script(installer: String) -> String {
        """
        #!/bin/bash
        # Written by the ADA menu bar's "Set Up Integrations…". Safe to delete.
        exec \(shellQuote(installer))

        """
    }

    /// Single-quoted for bash, with each embedded quote closed, escaped and reopened.
    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
