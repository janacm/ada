import Foundation

/// The ada install the menu bar helper drives: the directory that holds
/// `lib/ada-show-alert.sh`, which "Test Alert" runs and "Open ADA Folder" opens.
public enum InstallDirectory {
    /// The shared launcher, relative to the install directory.
    public static let launcherPath = "lib/ada-show-alert.sh"

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
                return ancestor.deletingLastPathComponent()
            }
            ancestor.deleteLastPathComponent()
        }
        return directory
    }

    /// The launcher inside `directory`, or nil when it is missing or not executable.
    public static func launcher(in directory: URL, fileManager: FileManager = .default) -> URL? {
        let url = directory.appendingPathComponent(launcherPath)
        return fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }
}
