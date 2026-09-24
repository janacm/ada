import Foundation

/// What choosing a menu item does. The AppKit delegate performs these; every
/// one that changes state goes through the script that owns that state.
public enum MenuAction: Equatable {
    case pause(minutes: Int)
    case pauseUntil(Date)
    case pauseUntilResumed
    case resume
    case open(ClickTarget)
    case clearHistory
    case unmute(key: String)
    case unmuteAll
    case setUp
    case testAlert
    case openFolder
    case quit
}

/// The menu, described without AppKit so it can be unit-tested and printed by
/// `ada-menubar --print-menu`.
public indirect enum MenuEntry: Equatable {
    /// A line you can't choose (the pause state, an integration's health).
    case info(String, symbol: String? = nil)
    case action(String, MenuAction, symbol: String? = nil)
    case submenu(String, [MenuEntry], symbol: String? = nil)
    case separator
}

public struct MenuInput {
    public var pause: PauseState
    public var history: [HistoryEntry]
    public var muted: [MutedSession]
    /// Nil while the integration check is still running.
    public var integrations: [IntegrationStatus]?
    public var now: Date
    public var calendar: Calendar
    public var recentLimit: Int

    public init(pause: PauseState, history: [HistoryEntry], muted: [MutedSession],
                integrations: [IntegrationStatus]?, now: Date, calendar: Calendar, recentLimit: Int = 10) {
        self.pause = pause
        self.history = history
        self.muted = muted
        self.integrations = integrations
        self.now = now
        self.calendar = calendar
        self.recentLimit = recentLimit
    }
}

public enum MenuModel {
    /// The status item's SF Symbol.
    public static func statusSymbol(for pause: PauseState) -> String {
        pause.isPaused ? "bell.slash" : "bell"
    }

    public static func build(_ input: MenuInput) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .info(input.pause.title(now: input.now, calendar: input.calendar), symbol: statusSymbol(for: input.pause)),
        ]
        if input.pause.isPaused {
            entries.append(.action("Resume Alerts", .resume, symbol: "bell"))
        }
        entries.append(.submenu(input.pause.isPaused ? "Change Pause" : "Pause Alerts", pauseEntries(input), symbol: "pause.circle"))
        entries.append(.separator)
        entries.append(.submenu("Recent Alerts", recentEntries(input), symbol: "clock"))
        entries.append(.submenu(input.muted.isEmpty ? "Muted Sessions" : "Muted Sessions (\(input.muted.count))",
                                mutedEntries(input), symbol: "bell.slash"))
        let warn = input.integrations?.contains { $0.state == .warn } ?? false
        entries.append(.submenu("Integrations", integrationEntries(input), symbol: warn ? "exclamationmark.triangle" : "puzzlepiece"))
        entries.append(.separator)
        entries.append(.action("Send Test Alert", .testAlert))
        entries.append(.action("Open ADA Folder", .openFolder))
        entries.append(.separator)
        entries.append(.action("Quit ADA Menu Bar", .quit))
        return entries
    }

    static func pauseEntries(_ input: MenuInput) -> [MenuEntry] {
        let morning = PauseState.nextMorning(after: input.now, calendar: input.calendar)
        return [
            .action("For 1 Hour", .pause(minutes: 60)),
            .action("Until \(PauseState.describe(morning, now: input.now, calendar: input.calendar))", .pauseUntil(morning)),
            .action("Until Resumed", .pauseUntilResumed),
        ]
    }

    static func recentEntries(_ input: MenuInput) -> [MenuEntry] {
        let recent = input.history.suffix(input.recentLimit).reversed()
        guard !recent.isEmpty else { return [.info("No Alerts Yet")] }
        var entries: [MenuEntry] = recent.map { entry in
            let title = historyTitle(entry, now: input.now, calendar: input.calendar)
            let symbol = historySymbol(entry)
            if let target = entry.clickTarget {
                return .action(title, .open(target), symbol: symbol)
            }
            return .info(title, symbol: symbol)
        }
        entries.append(.separator)
        entries.append(.action("Clear History", .clearHistory))
        return entries
    }

    static func historyTitle(_ entry: HistoryEntry, now: Date, calendar: Calendar) -> String {
        var parts = [truncate(entry.label.isEmpty ? "(no label)" : entry.label, to: 60)]
        if !entry.repo.isEmpty { parts.append(entry.repo) }
        if !entry.duration.isEmpty { parts.append(entry.duration) }
        parts.append(PauseState.describe(entry.date, now: now, calendar: calendar))
        var title = parts.joined(separator: " · ")
        switch entry.outcome {
        case .paused: title += " (while paused)"
        case .muted: title += " (muted)"
        case .shown: if entry.snoozed { title += " (snoozed)" }
        }
        return title
    }

    static func historySymbol(_ entry: HistoryEntry) -> String {
        switch entry.outcome {
        case .paused: return "pause.circle"
        case .muted: return "bell.slash"
        case .shown: return entry.failed ? "xmark.circle" : "checkmark.circle"
        }
    }

    static func mutedEntries(_ input: MenuInput) -> [MenuEntry] {
        guard !input.muted.isEmpty else { return [.info("Nothing Muted")] }
        var entries: [MenuEntry] = [.info("Choose One to Unmute It")]
        for session in input.muted {
            let what = session.label.map { "\(truncate($0, to: 60)) · \(session.kind)" } ?? "\(session.kind) \(session.shortID)"
            let title = "\(what) · \(age(from: session.mutedAt, to: input.now))"
            entries.append(.action(title, .unmute(key: session.key), symbol: "bell.slash"))
        }
        entries.append(.separator)
        entries.append(.action("Unmute All", .unmuteAll))
        return entries
    }

    public static func integrationEntries(_ input: MenuInput) -> [MenuEntry] {
        var entries: [MenuEntry]
        if let integrations = input.integrations {
            entries = integrations.map { status in
                .info("\(status.name): \(status.detail)", symbol: integrationSymbol(status.state))
            }
            if entries.isEmpty { entries = [.info("No Report")] }
        } else {
            entries = [.info("Checking…")]
        }
        entries.append(.separator)
        entries.append(.action("Set Up Integrations…", .setUp))
        return entries
    }

    static func integrationSymbol(_ state: IntegrationStatus.State) -> String {
        switch state {
        case .ok: return "checkmark.circle"
        case .off: return "circle"
        case .warn: return "exclamationmark.triangle"
        case .unavailable: return "circle.dashed"
        }
    }

    /// "just now", "5m ago", "2h ago", "3d ago".
    public static func age(from date: Date, to now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// The menu as text, one entry per line, submenus indented. Chosen actions
    /// start with "- ", lines you can't choose with "  ", submenus with "> ",
    /// and the SF Symbol follows in brackets.
    public static func render(_ entries: [MenuEntry], depth: Int = 0) -> String {
        let indent = String(repeating: "    ", count: depth)
        var lines: [String] = []
        for entry in entries {
            switch entry {
            case .separator:
                lines.append(indent + "---")
            case let .info(title, symbol):
                lines.append(indent + "  " + title + suffix(symbol))
            case let .action(title, _, symbol):
                lines.append(indent + "- " + title + suffix(symbol))
            case let .submenu(title, children, symbol):
                lines.append(indent + "> " + title + suffix(symbol))
                lines.append(render(children, depth: depth + 1))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func suffix(_ symbol: String?) -> String {
        symbol.map { " [\($0)]" } ?? ""
    }
}
