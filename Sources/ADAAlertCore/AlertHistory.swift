import Foundation

/// Where clicking an alert takes you, the rule the snooze daemon's focus branch
/// applies: the click URL (a `claude://resume?session=…` deep link) first, then
/// the app that raised the alert.
public enum ClickTarget: Equatable {
    case url(URL)
    case application(bundleIdentifier: String)

    /// Nil when neither is usable. A `file:` URL is refused so a line in the
    /// history can't open a local file or app bundle, and a bundle id must look
    /// like one (letters, digits, `.` and `-`).
    public static func from(clickURL: String, focusApp: String) -> ClickTarget? {
        if !clickURL.isEmpty, let url = URL(string: clickURL),
           let scheme = url.scheme?.lowercased(), !scheme.isEmpty, scheme != "file" {
            return .url(url)
        }
        if !focusApp.isEmpty, focusApp.count <= 255,
           focusApp.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "." || $0 == "-" }) {
            return .application(bundleIdentifier: focusApp)
        }
        return nil
    }
}

/// One alert the launcher decided on, from a line of `lib/ada-history.sh`'s file.
public struct HistoryEntry: Equatable {
    public enum Outcome: String {
        case shown, paused, muted
    }

    public let date: Date
    public let outcome: Outcome
    /// A snooze relaunch, rather than the first time the alert came up.
    public let snoozed: Bool
    public let sessionKey: String
    public let sessionKind: String
    public let label: String
    public let duration: String
    public let exitCode: Int?
    public let repo: String
    public let focusApp: String
    public let focusAppName: String
    public let clickURL: String

    public var clickTarget: ClickTarget? {
        ClickTarget.from(clickURL: clickURL, focusApp: focusApp)
    }

    public var failed: Bool {
        (exitCode ?? 0) != 0
    }
}

/// The alert history `lib/ada-history.sh` documents: one tab-separated line
/// per alert, version first, oldest first.
public enum AlertHistory {
    /// Format v1 has 13 columns. Lines of another version, or with fewer
    /// columns, are skipped; columns past the 13th are ignored, so a newer
    /// launcher can add some without breaking this reader.
    static let columns = 13

    public static func parse(_ text: String) -> [HistoryEntry] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= columns, fields[0] == "1",
                  let epoch = TimeInterval(fields[1]),
                  let outcome = HistoryEntry.Outcome(rawValue: fields[2])
            else {
                return nil
            }
            return HistoryEntry(
                date: Date(timeIntervalSince1970: epoch),
                outcome: outcome,
                snoozed: fields[3] == "1",
                sessionKey: fields[4],
                sessionKind: fields[5],
                label: fields[6],
                duration: fields[7],
                exitCode: Int(fields[8]),
                repo: fields[9],
                focusApp: fields[10],
                focusAppName: fields[11],
                clickURL: fields[12]
            )
        }
    }

    /// The history file's entries, oldest first. Only a regular file owned by
    /// this user is read (the shared `/tmp` fallback could hold anyone's), and
    /// only its last `maxBytes`, so a runaway file can't stall the menu.
    public static func read(fileAt url: URL, maxBytes: Int = 1 << 20, fileManager: FileManager = .default) -> [HistoryEntry] {
        guard isRegularFile(url, fileManager: fileManager),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let handle = FileHandle(forReadingAtPath: url.path)
        else {
            return []
        }
        defer { try? handle.close() }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        var skipFirstLine = false
        if size > maxBytes {
            handle.seek(toFileOffset: UInt64(size - maxBytes))
            skipFirstLine = true
        }
        let data = handle.readDataToEndOfFile()
        var text = String(decoding: data, as: UTF8.self)
        if skipFirstLine, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return parse(text)
    }

    /// The label of the newest alert for a session, for naming a muted session
    /// whose marker predates marker labels.
    public static func latestLabel(forSessionKey key: String, in entries: [HistoryEntry]) -> String? {
        entries.last(where: { $0.sessionKey == key && !$0.label.isEmpty })?.label
    }
}
