import Foundation

/// A release newer than this install.
public struct AvailableUpdate: Equatable {
    public let installed: String
    public let latest: String

    public init(installed: String, latest: String) {
        self.installed = installed
        self.latest = latest
    }
}

/// Whether a newer ada is out, read from the two files `lib/ada-update.sh`
/// uses: the `VERSION` file the Homebrew formula writes at the install root,
/// and the cache line `<epoch> <latest|-> <ok|failed|checking>` its background
/// check writes. The shell owns the check and every write; this only reads,
/// with the same rules: a version is two to four dot-separated numbers,
/// compared number by number, and `ADA_UPDATE_CHECK=0` or the off switch hides
/// the notice.
public enum UpdateCheck {
    /// What the notice tells you to run, as in `lib/ada-update.sh`.
    public static let command = "brew update && brew upgrade ada"

    /// "0.5", "1.2.3": two to four numbers of at most six digits.
    public static func isVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (2...4).contains(parts.count) && parts.allSatisfy { part in
            (1...6).contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    /// Number by number, a missing number counting as 0: 0.10 is newer than
    /// 0.9, and 0.5.0 is not newer than 0.5.
    public static func isNewer(_ version: String, than other: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The version in a `VERSION` file's first line, if it is a release
    /// version (a HEAD build's `HEAD-1a2b3c4` is not).
    public static func installed(fromVersionFile text: String) -> String? {
        let line = firstLine(text).trimmingCharacters(in: .whitespaces)
        return isVersion(line) ? line : nil
    }

    /// The newest version the last check found, from the cache's first line.
    /// A line whose epoch isn't a number reads as no check, as in the shell.
    public static func latest(fromCache text: String) -> String? {
        let fields = firstLine(text).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 2, (1...11).contains(fields[0].count),
              fields[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              isVersion(fields[1])
        else {
            return nil
        }
        return fields[1]
    }

    /// The off switch `ada-update.sh off` writes.
    public static func offFile(environment: [String: String]) -> URL {
        if let value = environment["ADA_UPDATE_OFF_FILE"], !value.isEmpty {
            return URL(fileURLWithPath: value)
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".local/share/ada/update-check-off")
    }

    public static func isEnabled(environment: [String: String], fileManager: FileManager = .default) -> Bool {
        if environment["ADA_UPDATE_CHECK"] == "0" { return false }
        let off = offFile(environment: environment).path
        // A symlink counts as present, dangling or not, as `-e || -L` does.
        if fileManager.fileExists(atPath: off) { return false }
        if (try? fileManager.destinationOfSymbolicLink(atPath: off)) != nil { return false }
        return true
    }

    /// The update to offer, or nil: checks off, no release `VERSION` (a
    /// checkout, a HEAD build), no usable cache, or nothing newer.
    public static func read(cacheAt cache: URL, installDirectory: URL, environment: [String: String],
                            fileManager: FileManager = .default) -> AvailableUpdate? {
        guard isEnabled(environment: environment, fileManager: fileManager) else { return nil }
        let versionFile = installDirectory.appendingPathComponent("VERSION")
        guard let versionData = fileManager.contents(atPath: versionFile.path),
              let installed = installed(fromVersionFile: String(decoding: versionData, as: UTF8.self)),
              isRegularFile(cache, fileManager: fileManager),
              let cacheData = fileManager.contents(atPath: cache.path),
              let latest = latest(fromCache: String(decoding: cacheData, as: UTF8.self)),
              isNewer(latest, than: installed)
        else {
            return nil
        }
        return AvailableUpdate(installed: installed, latest: latest)
    }

    /// The `.command` file the menu bar's update item opens in Terminal. A
    /// Homebrew install's directory names its prefix (`<prefix>/opt/ada/libexec`),
    /// so brew is run from there, in case Terminal's PATH lacks it.
    public static func script(installDirectory: URL) -> String {
        let path = installDirectory.standardizedFileURL.path
        var brew = "brew"
        if path.hasSuffix("/opt/ada/libexec") {
            let prefix = String(path.dropLast("/opt/ada/libexec".count))
            brew = SetupCommand.shellQuote(prefix + "/bin/brew")
        }
        return """
        #!/bin/bash
        # Written by the ADA menu bar's "Update ADA". Safe to delete.
        \(brew) update && \(brew) upgrade ada

        """
    }

    static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }
}
