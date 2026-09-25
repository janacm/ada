import Foundation

/// The ada install the menu bar helper drives: the directory that holds
/// `lib/ada-show-alert.sh`, which "Test Alert" runs and "Open ADA Folder" opens,
/// and the scripts behind the rest of the menu.
public enum InstallDirectory {
    /// The shared launcher, relative to the install directory.
    public static let launcherPath = "lib/ada-show-alert.sh"
    /// Pause and resume every alert.
    public static let pauseScriptPath = "lib/ada-pause.sh"
    /// Unmute a session.
    public static let muteScriptPath = "lib/ada-mute.sh"
    /// Clear the alert history.
    public static let historyScriptPath = "lib/ada-history.sh"
    /// Which integrations are wired.
    public static let statusScriptPath = "lib/ada-status.sh"

    /// `ADA_HOME` when it is set; otherwise the install the executable lives in.
    ///
    /// - Symlinks are resolved first. Homebrew runs the helper through
    ///   `bin/ada-menubar -> libexec/ada-menubar`, and `Bundle.main.executableURL`
    ///   reports the symlink's own path.
    /// - Inside an app bundle (`X.app/Contents/MacOS`) the install is the folder
    ///   holding the `.app`.
    /// - Inside a SwiftPM build directory the install is the package root that
    ///   holds `.build`: `.build/release` with the native build system, and
    ///   `.build/out/Products/Release` with Swift 6.4's default one.
    /// - A Homebrew keg is mapped to its version-stable `opt` path (`stable`).
    public static func resolve(environment: [String: String], executableURL: URL) -> URL {
        if let home = environment["ADA_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }

        var directory = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
        if directory.lastPathComponent == "MacOS" {
            directory = directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }

        var ancestor = directory
        while ancestor.pathComponents.count > 1 {
            if ancestor.lastPathComponent == ".build" {
                directory = ancestor.deletingLastPathComponent()
                break
            }
            ancestor.deleteLastPathComponent()
        }
        return stable(directory)
    }

    /// `<prefix>/opt/<name>/…` for a directory inside `<prefix>/Cellar/<name>/<version>/…`,
    /// when that `opt` directory exists; otherwise `directory` unchanged.
    ///
    /// Resolving Homebrew's `bin/` symlink lands in the versioned keg, which the
    /// next `brew upgrade` deletes while the menu bar keeps running with the path
    /// cached. The `opt` symlink names the same install and survives upgrades.
    /// This is the rule `__ada_stable_dir` applies in ada-install.sh and
    /// ada-paseo-watch.sh.
    public static func stable(_ directory: URL, fileManager: FileManager = .default) -> URL {
        let parts = directory.pathComponents
        guard let cellar = parts.firstIndex(of: "Cellar"), cellar + 2 < parts.count else {
            return directory
        }
        let opt = NSString.path(withComponents: Array(parts[..<cellar]) + ["opt", parts[cellar + 1]] + Array(parts[(cellar + 3)...]))
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: opt, isDirectory: &isDirectory), isDirectory.boolValue else {
            return directory
        }
        return URL(fileURLWithPath: opt, isDirectory: true)
    }

    /// The launcher inside `directory`, or nil when it is missing or not executable.
    public static func launcher(in directory: URL, fileManager: FileManager = .default) -> URL? {
        script(launcherPath, in: directory, fileManager: fileManager)
    }

    /// `relativePath` inside `directory`, or nil when it is missing or not executable.
    public static func script(_ relativePath: String, in directory: URL, fileManager: FileManager = .default) -> URL? {
        let url = directory.appendingPathComponent(relativePath)
        return fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }
}
