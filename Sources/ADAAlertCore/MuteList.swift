import Foundation

/// A session muted from an alert's "Mute this …" button.
public struct MutedSession: Equatable {
    public let key: String
    public let mutedAt: Date
    /// The label of the alert it was muted from: the marker's first line, else
    /// the newest history line for the key.
    public let label: String?

    /// What kind of session the key names, from the prefix each integration
    /// uses (see lib/ada-mute.sh).
    public var kind: String {
        if key.hasPrefix("claude-") { return "Claude Code conversation" }
        if key.hasPrefix("opencode-") { return "opencode session" }
        if key.hasPrefix("paseo-") { return "Paseo agent" }
        if key.hasPrefix("zsh-") { return "terminal" }
        return "session"
    }

    /// The id part of the key, cut to 8 characters: enough to tell two
    /// unlabelled sessions apart without a 36-character UUID in the menu.
    public var shortID: String {
        let id = key.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init) ?? key
        return String(id.prefix(8))
    }
}

/// The mute markers, read straight from their directory, applying the rules
/// `lib/ada-mute.sh` documents: a marker is a regular file (not a symlink)
/// directly inside `ADA_MUTE_DIR`, named after a valid key, and it counts while
/// its age is within `ADA_MUTE_MAX_AGE`. Reading the directory, rather than
/// running `ada-mute.sh list` for every menu open, keeps the menu instant; the
/// menu still unmutes through the script, which owns every write.
public enum MuteList {
    public static let defaultMaxAge: TimeInterval = 86400

    /// Seconds a mute lasts, or nil for "until cleared" (`0`). Anything that
    /// isn't 1 to 15 digits falls back to the default, and leading zeros are
    /// decimal, as in `__ada_mute_max_age`.
    public static func maxAge(environment: [String: String]) -> TimeInterval? {
        guard let raw = environment["ADA_MUTE_MAX_AGE"], !raw.isEmpty else { return defaultMaxAge }
        guard (1...15).contains(raw.count), raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int64(raw)
        else {
            return defaultMaxAge
        }
        return value == 0 ? nil : TimeInterval(value)
    }

    /// `^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$`, the rule that keeps a key a plain
    /// file name.
    public static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, key.unicodeScalars.count <= 200 else { return false }
        func plain(_ scalar: Unicode.Scalar) -> Bool {
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
        }
        return plain(first) && key.unicodeScalars.allSatisfy { plain($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// Muted sessions, the most recently muted first.
    public static func read(
        directory: URL,
        maxAge: TimeInterval?,
        now: Date,
        history: [HistoryEntry] = [],
        fileManager: FileManager = .default
    ) -> [MutedSession] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name -> MutedSession? in
            guard isValidKey(name) else { return nil }
            let url = directory.appendingPathComponent(name)
            guard isRegularFile(url, fileManager: fileManager),
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date
            else {
                return nil
            }
            // The shell compares whole seconds: muted while now - mtime <= max.
            let age = floor(now.timeIntervalSince1970) - floor(modified.timeIntervalSince1970)
            if let maxAge, age > maxAge { return nil }
            return MutedSession(key: name, mutedAt: modified, label: label(of: url, key: name, history: history, fileManager: fileManager))
        }
        .sorted { $0.mutedAt > $1.mutedAt }
    }

    static func label(of url: URL, key: String, history: [HistoryEntry], fileManager: FileManager) -> String? {
        if let data = fileManager.contents(atPath: url.path), !data.isEmpty {
            let first = String(decoding: data.prefix(1024), as: UTF8.self)
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return AlertHistory.latestLabel(forSessionKey: key, in: history)
    }
}
