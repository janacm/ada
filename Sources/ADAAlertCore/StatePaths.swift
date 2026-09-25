import Foundation

/// Where the shell side keeps the state the menu bar reads: the pause file, the
/// alert history and the mute markers, all under the per-user temp dir.
///
/// The rules mirror the scripts that own each file (`lib/ada-pause.sh`,
/// `lib/ada-history.sh`, `lib/ada-mute.sh`) and the launcher's TMPDIR fallback
/// in `lib/ada-show-alert.sh`: `TMPDIR` when it is set, else the Darwin
/// per-user temp dir (`getconf DARWIN_USER_TEMP_DIR`), else `/tmp`. launchd
/// gives a LaunchAgent the same per-user dir as a terminal, which is what lets
/// the menu bar see a pause set from the command line.
public struct StatePaths: Equatable {
    public let tempDirectory: URL
    public let pauseFile: URL
    public let historyFile: URL
    public let muteDirectory: URL
    /// Held by the running menu bar so a second copy exits.
    public let lockFile: URL

    public static func resolve(
        environment: [String: String],
        darwinTempDirectory: () -> String? = StatePaths.darwinUserTempDirectory
    ) -> StatePaths {
        let temp: String
        if let value = environment["TMPDIR"], !value.isEmpty {
            temp = value
        } else if let value = darwinTempDirectory(), !value.isEmpty {
            temp = value
        } else {
            temp = "/tmp"
        }
        let tempURL = URL(fileURLWithPath: temp, isDirectory: true)
        func file(_ variable: String, default name: String) -> URL {
            if let value = environment[variable], !value.isEmpty {
                return URL(fileURLWithPath: value)
            }
            return tempURL.appendingPathComponent(name)
        }
        return StatePaths(
            tempDirectory: tempURL,
            pauseFile: file("ADA_PAUSE_FILE", default: "ada-paused"),
            historyFile: file("ADA_HISTORY_FILE", default: "ada-history.tsv"),
            muteDirectory: file("ADA_MUTE_DIR", default: "ada-muted"),
            lockFile: tempURL.appendingPathComponent("ada-menubar.lock")
        )
    }

    /// `confstr(_CS_DARWIN_USER_TEMP_DIR)`, what `getconf DARWIN_USER_TEMP_DIR` prints.
    public static func darwinUserTempDirectory() -> String? {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// A regular file (not a symlink, not a directory), as the scripts require
/// before they read or write any of this state.
func isRegularFile(_ url: URL, fileManager: FileManager = .default) -> Bool {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return false }
    return (attributes[.type] as? FileAttributeType) == .typeRegular
}
