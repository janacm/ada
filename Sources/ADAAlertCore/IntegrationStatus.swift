import Foundation

/// One row of `lib/ada-status.sh`'s report: `id\tstate\tname\tdetail`. The
/// shell owns the checks and the wording; the menu bar shows them as they are.
public struct IntegrationStatus: Equatable {
    public enum State: String {
        case ok, off, warn, unavailable
    }

    public let id: String
    public let state: State
    public let name: String
    public let detail: String

    public init(id: String, state: State, name: String, detail: String) {
        self.id = id
        self.state = state
        self.name = name
        self.detail = detail
    }

    /// Rows with too few fields are skipped. A state this reader doesn't know
    /// is shown as a warning rather than dropped, so a newer report can't hide
    /// a problem from an older menu bar.
    public static func parse(_ text: String) -> [IntegrationStatus] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, !fields[0].isEmpty else { return nil }
            return IntegrationStatus(
                id: fields[0],
                state: State(rawValue: fields[1]) ?? .warn,
                name: fields[2],
                detail: fields[3]
            )
        }
    }
}

/// `stage-info`, which staging writes beside the runtime: key=value lines
/// naming the checkout the stage came from. It lets a staged menu bar name its
/// checkout without reading it (it may be under ~/Documents, which a
/// LaunchAgent may not look inside).
public struct StageInfo: Equatable {
    public let source: String?
    public let rev: String?
    public let dirty: Bool
    public let stagedAt: Date?
    public let stagedBy: String?

    public static func parse(_ text: String) -> StageInfo {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        func nonEmpty(_ key: String) -> String? {
            guard let value = values[key], !value.isEmpty else { return nil }
            return value
        }
        return StageInfo(
            source: nonEmpty("source"),
            rev: nonEmpty("rev"),
            dirty: values["dirty"] == "1",
            stagedAt: nonEmpty("staged_at").flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) },
            stagedBy: nonEmpty("by")
        )
    }

    public static func read(in installDirectory: URL, fileManager: FileManager = .default) -> StageInfo? {
        let url = installDirectory.appendingPathComponent("stage-info")
        guard isRegularFile(url, fileManager: fileManager),
              let data = fileManager.contents(atPath: url.path)
        else {
            return nil
        }
        return parse(String(decoding: data, as: UTF8.self))
    }
}
