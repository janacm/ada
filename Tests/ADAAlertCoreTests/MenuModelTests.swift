import Foundation
import Testing
@testable import ADAAlertCore

// The menu, as the AppKit delegate renders it and --print-menu prints it.
@Suite struct MenuModelTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // 2026-09-24 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_251_200)

    private func entry(_ label: String, outcome: String = "shown", code: String = "0", key: String = "claude-a",
                       ago: TimeInterval = 60, url: String = "claude://resume?session=a", snoozed: String = "0") -> String {
        ["1", String(Int(now.timeIntervalSince1970 - ago)), outcome, snoozed, key, "conversation", label, "2m 3s", code,
         "ada", "com.example.term", "Example", url].joined(separator: "\t")
    }

    private func input(pause: PauseState = .active, history: [String] = [], muted: [MutedSession] = [],
                       integrations: [IntegrationStatus]? = [], update: AvailableUpdate? = nil) -> MenuInput {
        MenuInput(pause: pause, history: AlertHistory.parse(history.joined(separator: "\n")), muted: muted,
                  integrations: integrations, now: now, calendar: calendar, update: update)
    }

    @Test func anUpdateComesFirstAndNothingWithoutOne() {
        let entries = MenuModel.build(input(update: AvailableUpdate(installed: "0.4", latest: "0.5")))
        #expect(entries[0] == .action("Update to ADA 0.5 (You Have 0.4)…", .update, symbol: "arrow.down.circle"))
        #expect(entries[1] == .separator)
        #expect(entries[2] == .info("Alerts On", symbol: "bell"))
        #expect(!MenuModel.build(input()).contains { if case .action(_, .update, _) = $0 { return true }; return false })
    }

    private func submenu(_ title: String, in entries: [MenuEntry]) -> [MenuEntry]? {
        for case let .submenu(name, children, _) in entries where name.hasPrefix(title) {
            return children
        }
        return nil
    }

    @Test func activeMenuOffersPauseAndNoResume() throws {
        let entries = MenuModel.build(input())
        #expect(entries.first == .info("Alerts On", symbol: "bell"))
        #expect(!entries.contains(.action("Resume Alerts", .resume, symbol: "bell")))
        let pause = try #require(submenu("Pause Alerts", in: entries))
        #expect(pause[0] == .action("For 1 Hour", .pause(minutes: 60)))
        #expect(pause[1] == .action("Until Tomorrow 08:00",
                                    .pauseUntil(Date(timeIntervalSince1970: 1_790_323_200))))
        #expect(pause[2] == .action("Until Resumed", .pauseUntilResumed))
        #expect(MenuModel.statusSymbol(for: .active) == "bell")
    }

    @Test func pausedMenuOffersResumeAndAChange() {
        let entries = MenuModel.build(input(pause: .paused(until: nil)))
        #expect(entries.first == .info("Paused Until Resumed", symbol: "bell.slash"))
        #expect(entries[1] == .action("Resume Alerts", .resume, symbol: "bell"))
        #expect(submenu("Change Pause", in: entries) != nil)
        #expect(MenuModel.statusSymbol(for: .paused(until: nil)) == "bell.slash")
    }

    @Test func recentAlertsAreNewestFirstAndCapped() throws {
        let history = (1...12).map { entry("alert \($0)", ago: TimeInterval(1000 - $0)) }
        let recent = try #require(submenu("Recent Alerts", in: MenuModel.build(input(history: history))))
        let titles = recent.compactMap { entry -> String? in
            if case let .action(title, .open, _) = entry { return title }
            return nil
        }
        #expect(titles.count == 10)
        #expect(titles.first?.hasPrefix("alert 12 · ada · 2m 3s · ") == true)
        #expect(titles.last?.hasPrefix("alert 3 ") == true)
        #expect(recent.last == .action("Clear History", .clearHistory))
    }

    @Test func recentAlertsMarkDroppedFailedAndSnoozed() throws {
        let history = [
            entry("ok one", ago: 400),
            entry("broke", code: "2", ago: 300),
            entry("while away", outcome: "paused", ago: 200),
            entry("quiet", outcome: "muted", ago: 100),
            entry("held back", outcome: "held", ago: 75),
            entry("again", ago: 50, snoozed: "1"),
            entry("no target", ago: 10, url: "").replacingOccurrences(of: "com.example.term", with: ""),
        ]
        let recent = try #require(submenu("Recent Alerts", in: MenuModel.build(input(history: history))))
        func find(_ prefix: String) -> MenuEntry? {
            recent.first { entry in
                switch entry {
                case let .action(title, _, _), let .info(title, _): return title.hasPrefix(prefix)
                default: return false
                }
            }
        }
        if case let .action(_, _, symbol)? = find("ok one") { #expect(symbol == "checkmark.circle") } else { Issue.record("ok one") }
        if case let .action(_, _, symbol)? = find("broke") { #expect(symbol == "xmark.circle") } else { Issue.record("broke") }
        if case let .action(title, _, symbol)? = find("while away") {
            #expect(title.hasSuffix("(while paused)")); #expect(symbol == "pause.circle")
        } else { Issue.record("while away") }
        if case let .action(title, _, _)? = find("quiet") { #expect(title.hasSuffix("(muted)")) } else { Issue.record("quiet") }
        if case let .action(title, _, symbol)? = find("held back") {
            #expect(title.hasSuffix("(while snoozed)")); #expect(symbol == "alarm")
        } else { Issue.record("held back") }
        if case let .action(title, _, _)? = find("again") { #expect(title.hasSuffix("(snoozed)")) } else { Issue.record("again") }
        // Nowhere to go: shown, but not choosable.
        if case .info? = find("no target") {} else { Issue.record("no target should be info") }
    }

    @Test func emptyStatesSaySo() throws {
        let entries = MenuModel.build(input(integrations: nil))
        #expect(try #require(submenu("Recent Alerts", in: entries)) == [.info("No Alerts Yet")])
        #expect(try #require(submenu("Muted Sessions", in: entries)) == [.info("Nothing Muted")])
        #expect(try #require(submenu("Integrations", in: entries)).first == .info("Checking…"))
    }

    @Test func mutedSessionsUnmuteOnChoice() throws {
        let muted = [MutedSession(key: "claude-a", mutedAt: now.addingTimeInterval(-7200), label: "fix the flaky test")]
        let entries = MenuModel.build(input(muted: muted))
        let menu = try #require(submenu("Muted Sessions (1)", in: entries))
        #expect(menu.contains(.action("fix the flaky test · Claude Code conversation · 2h ago",
                                      .unmute(key: "claude-a"), symbol: "bell.slash")))
        #expect(menu.last == .action("Unmute All", .unmuteAll))
    }

    @Test func anUnlabelledMuteShowsItsKindAndAShortID() throws {
        let muted = [MutedSession(key: "claude-6b1a216c-6946-43d8-9d43-90fe18e51bb6", mutedAt: now.addingTimeInterval(-60), label: nil)]
        let menu = try #require(submenu("Muted Sessions (1)", in: MenuModel.build(input(muted: muted))))
        #expect(menu.contains(.action("Claude Code conversation 6b1a216c · 1m ago",
                                      .unmute(key: "claude-6b1a216c-6946-43d8-9d43-90fe18e51bb6"), symbol: "bell.slash")))
        #expect(MutedSession(key: "zsh-4242-1790000000", mutedAt: now, label: nil).shortID == "4242-179")
    }

    @Test func integrationsShowTheReportAndFlagAWarning() throws {
        let report = IntegrationStatus.parse("claude\tok\tClaude Code\thooks run /x\nopencode\twarn\topencode\tplugin missing\n")
        let entries = MenuModel.build(input(integrations: report))
        let menu = try #require(submenu("Integrations", in: entries))
        #expect(menu[0] == .info("Claude Code: hooks run /x", symbol: "checkmark.circle"))
        #expect(menu[1] == .info("opencode: plugin missing", symbol: "exclamationmark.triangle"))
        #expect(menu.last == .action("Set Up Integrations…", .setUp))
        #expect(entries.contains { if case .submenu("Integrations", _, "exclamationmark.triangle") = $0 { return true }; return false })
    }

    @Test func longLabelsAreTruncated() {
        let title = MenuModel.historyTitle(AlertHistory.parse(entry(String(repeating: "x", count: 80)))[0], now: now, calendar: calendar)
        #expect(title.hasPrefix(String(repeating: "x", count: 59) + "… · ada"))
    }

    @Test func ages() {
        #expect(MenuModel.age(from: now.addingTimeInterval(-30), to: now) == "just now")
        #expect(MenuModel.age(from: now.addingTimeInterval(-300), to: now) == "5m ago")
        #expect(MenuModel.age(from: now.addingTimeInterval(-7300), to: now) == "2h ago")
        #expect(MenuModel.age(from: now.addingTimeInterval(-200_000), to: now) == "2d ago")
    }

    // --- the source switches ---------------------------------------------------

    /// A history line with the repo and source columns set.
    private func sourced(_ source: String, repo: String = "ada", ago: TimeInterval = 60) -> String {
        ["1", String(Int(now.timeIntervalSince1970 - ago)), "shown", "0", "k", "agent", "l", "1s", "0",
         repo, "", "", "", "/d", source].joined(separator: "\t")
    }

    private func sources(_ rules: String = "", history: [String] = []) throws -> [MenuEntry] {
        var menuInput = input(history: history)
        menuInput.sources = SourceRules.parse(rules)
        return try #require(submenu("Alert Sources", in: MenuModel.build(menuInput)))
    }

    @Test func sourcesListEverySwitchAndAChoiceFlipsIt() throws {
        let entries = try sources()
        #expect(entries.prefix(11) == [
            .toggle("Terminal Commands", isOn: true, .setSource(key: "terminal", on: false)),
            .toggle("Claude Code", isOn: true, .setSource(key: "claude", on: false)),
            .toggle("Desktop App", isOn: true, .setSource(key: "claude/desktop", on: false), indent: 1),
            .toggle("Terminal", isOn: true, .setSource(key: "claude/cli", on: false), indent: 1),
            .toggle("IDE", isOn: true, .setSource(key: "claude/ide", on: false), indent: 1),
            .toggle("Headless (claude -p, Agent SDK)", isOn: false, .setSource(key: "claude/headless", on: true), indent: 1),
            .toggle("Codex", isOn: true, .setSource(key: "codex", on: false)),
            .toggle("opencode", isOn: true, .setSource(key: "opencode", on: false)),
            .toggle("Paseo", isOn: true, .setSource(key: "paseo", on: false)),
            .separator,
            .submenu("Projects", MenuModel.projectEntries(input()), symbol: "folder"),
        ])
        #expect(entries.suffix(2) == [.action("Edit Rules File…", .editSources), .action("Reset to Defaults", .resetSources)])
        #expect(MenuModel.build(input()).contains { if case .submenu("Alert Sources", _, "switch.2") = $0 { return true }; return false })
    }

    @Test func paseoProvidersComeFromTheHistoryAndTheRules() throws {
        let entries = try sources("off source paseo\non source paseo/claude\noff source paseo/bad key",
                                  history: [sourced("paseo/cursor"), sourced("paseo/codex"), sourced("paseo/cursor"),
                                            sourced("claude/cli"), sourced("paseo/a/b"), sourced("")])
        let paseo = try #require(entries.firstIndex(of: .toggle("Paseo", isOn: false, .setSource(key: "paseo", on: true))))
        #expect(Array(entries[(paseo + 1)...].prefix(4)) == [
            .toggle("claude", isOn: true, .setSource(key: "paseo/claude", on: false), indent: 1),
            .toggle("codex", isOn: false, .setSource(key: "paseo/codex", on: true), indent: 1),
            .toggle("cursor", isOn: false, .setSource(key: "paseo/cursor", on: true), indent: 1),
            .separator,
        ])
    }

    @Test func projectsComeFromTheRulesAndTheHistoryAlphabetically() throws {
        var menuInput = input(history: [sourced("terminal", repo: "zeta"), sourced("terminal", repo: "ada"),
                                        sourced("terminal", repo: "")])
        menuInput.sources = SourceRules.parse("off repo Sandbox")
        #expect(MenuModel.projectEntries(menuInput) == [
            .toggle("All Projects", isOn: true, .setRepoMode(onlyListed: false)),
            .toggle("Only Checked Projects", isOn: false, .setRepoMode(onlyListed: true)),
            .separator,
            .toggle("ada", isOn: true, .setRepo(name: "ada", on: false)),
            .toggle("Sandbox", isOn: false, .setRepo(name: "Sandbox", on: true)),
            .toggle("zeta", isOn: true, .setRepo(name: "zeta", on: false)),
        ])
        #expect(MenuModel.projectEntries(input()).last == .info("Projects Appear Here After They Alert"))
    }

    @Test func onlyCheckedProjectsSaysWhenNothingIsChecked() throws {
        var menuInput = input(history: [sourced("terminal", repo: "ada")])
        menuInput.sources = SourceRules.parse("off repo *")
        let entries = MenuModel.projectEntries(menuInput)
        #expect(entries[1] == .toggle("Only Checked Projects", isOn: true, .setRepoMode(onlyListed: true)))
        #expect(entries[3] == .info("Nothing Alerts Until You Check a Project"))
        #expect(entries[4] == .toggle("ada", isOn: false, .setRepo(name: "ada", on: true)))
        #expect(try sources("off repo *").contains { if case .submenu("Projects (Only Checked)", _, _) = $0 { return true }; return false })
    }

    @Test func historyProjectsAreCappedButNamedOnesAlwaysShow() {
        var menuInput = input(history: (1...30).map { sourced("terminal", repo: "r\($0)", ago: TimeInterval(100 - $0)) })
        menuInput.sources = SourceRules.parse("off repo named")
        let names = MenuModel.projectEntries(menuInput, limit: 5).compactMap { entry -> String? in
            if case let .toggle(title, _, .setRepo, _) = entry { return title }
            return nil
        }
        #expect(names == ["named", "r27", "r28", "r29", "r30"])
    }

    @Test func historyReadsTheSourceColumn() throws {
        #expect(AlertHistory.parse(sourced("paseo/codex")).first?.source == "paseo/codex")
        #expect(AlertHistory.parse(entry("old line")).first?.source == "")
    }

    @Test func rendersSwitchesWithTheirState() {
        #expect(MenuModel.render([
            .toggle("Paseo", isOn: false, .setSource(key: "paseo", on: true)),
            .toggle("claude", isOn: true, .setSource(key: "paseo/claude", on: false), indent: 1),
        ]) == "- [ ] Paseo\n- [x]   claude")
    }

    @Test func rendersAsIndentedText() {
        let text = MenuModel.render([
            .info("Alerts On", symbol: "bell"),
            .submenu("Pause Alerts", [.action("For 1 Hour", .pause(minutes: 60))]),
            .separator,
            .action("Quit ADA Menu Bar", .quit),
        ])
        #expect(text == """
          Alerts On [bell]
        > Pause Alerts
            - For 1 Hour
        ---
        - Quit ADA Menu Bar
        """)
    }
}
