import Foundation
import Testing
@testable import ADAAlertCore

// Reading lib/ada-sources.sh's rules file the way the script does. The script's
// side is pinned by test/ada-sources.bats, and test/ada-alert.bats checks that
// --print-menu and `ada-sources.sh check` agree on real rules.
@Suite struct SourceRulesTests {
    @Test func noRulesMeansEverythingButHeadlessClaude() {
        let rules = SourceRules()
        #expect(rules.source("terminal") == (true, .none))
        #expect(rules.source("claude/desktop") == (true, .none))
        #expect(rules.source("claude/headless") == (false, .defaultRule("claude/headless")))
        #expect(rules.source("paseo/cursor") == (true, .none))
        #expect(rules.repo("ada") == (true, .none))
        #expect(rules.allows(source: "codex", repo: ""))
        #expect(!rules.hasRepoRules)
    }

    @Test func theMostSpecificRuleWins() {
        let rules = SourceRules.parse("off source paseo\non source paseo/claude\n")
        #expect(rules.source("paseo/claude") == (true, .rule("paseo/claude")))
        #expect(rules.source("paseo/codex") == (false, .rule("paseo")))
        #expect(rules.source("paseo") == (false, .rule("paseo")))
        #expect(rules.source("terminal") == (true, .none))
    }

    @Test func aDefaultIsReplacedOnlyByARuleOfItsOwnName() {
        #expect(SourceRules.parse("on source claude").source("claude/headless").isOn == false)
        #expect(SourceRules.parse("on source *").source("claude/headless").isOn == false)
        #expect(SourceRules.parse("on source claude/headless").source("claude/headless") == (true, .rule("claude/headless")))
        #expect(SourceRules.parse("off source *").source("terminal") == (false, .rule("*")))
    }

    @Test func aLaterLineReplacesAnEarlierOne() {
        let rules = SourceRules.parse("off source codex\non source codex\noff repo x\non repo x")
        #expect(rules.source("codex").isOn)
        #expect(rules.repo("x").isOn)
    }

    @Test func projectsAreOnUnlessTurnedOffOrOutsideAnAllowlist() {
        let off = SourceRules.parse("off repo sandbox")
        #expect(off.repo("sandbox") == (false, .rule("sandbox")))
        #expect(off.repo("ada").isOn)
        #expect(!off.onlyListedRepos)

        let only = SourceRules.parse("off repo *\non repo ada\non repo My Project")
        #expect(only.onlyListedRepos)
        #expect(only.repo("ada").isOn)
        #expect(only.repo("My Project").isOn)
        #expect(only.repo("other") == (false, .rule("*")))
        #expect(only.repo("") == (false, .rule("*")))
        #expect(only.namedRepos == ["ada", "My Project"])
        #expect(!only.allows(source: "terminal", repo: "other"))
        #expect(only.allows(source: "terminal", repo: "ada"))
        #expect(!SourceRules.parse("off repo *\non repo ada\noff source codex").allows(source: "codex", repo: "ada"))
    }

    @Test func linesAreReadLikeTheScriptReadsThem() {
        let text = "# comment\n\n  off   source   codex  \r\nnonsense here\non source bad key\non repo   spaced name  \n"
            + "maybe source x\non thing x\noff source paseo//x\noff source -x\non repo \t\n"
        let rules = SourceRules.parse(text)
        #expect(rules.rules == [
            SourceRules.Rule(isOn: false, kind: .source, name: "codex"),
            SourceRules.Rule(isOn: true, kind: .repo, name: "spaced name"),
        ])
    }

    @Test(arguments: [
        ("*", true), ("terminal", true), ("paseo/claude", true), ("a.b_c-d/e1", true),
        ("", false), ("-x", false), ("a//b", false), ("a/", false), ("bad key", false), ("é", false),
        (String(repeating: "a", count: 101), false),
    ])
    func sourceKeys(_ key: String, _ valid: Bool) {
        #expect(SourceRules.isValidSource(key) == valid)
    }

    @Test func readsThroughASymlinkAndIgnoresAMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real")
        try "off source paseo\n".write(to: target, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("sources")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(SourceRules.read(fileAt: link).source("paseo").isOn == false)
        #expect(SourceRules.read(fileAt: dir.appendingPathComponent("none")) == SourceRules())
        #expect(SourceRules.read(fileAt: dir) == SourceRules())
    }

    @Test func theRulesFileLivesUnderHomeUnlessNamed() {
        let paths = StatePaths.resolve(environment: ["TMPDIR": "/t", "HOME": "/Users/x"], darwinTempDirectory: { nil })
        #expect(paths.sourcesFile.path == "/Users/x/.config/ada/sources")
        let named = StatePaths.resolve(environment: ["ADA_SOURCES_FILE": "/r"], darwinTempDirectory: { nil })
        #expect(named.sourcesFile.path == "/r")
        let fallback = StatePaths.resolve(environment: [:], darwinTempDirectory: { nil }, homeDirectory: { "/h" })
        #expect(fallback.sourcesFile.path == "/h/.config/ada/sources")
    }
}
