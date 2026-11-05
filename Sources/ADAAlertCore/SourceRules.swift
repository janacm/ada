import Foundation

/// The source switches `lib/ada-sources.sh` keeps in `~/.config/ada/sources`:
/// which agents, harnesses and projects may raise an alert. The launcher applies
/// them; the menu bar only reads them here, with the script's rules, and changes
/// them by running the script.
///
/// One rule per line, `#` starts a comment:
///
///     off source paseo
///     on source paseo/claude
///     off repo *
///     on repo ada
///
/// The most specific source rule wins (`paseo/claude`, then `paseo`, then `*`),
/// taking a rule from the file before a built-in default at each step. A project
/// rule names a repo folder, or `*` for every project.
public struct SourceRules: Equatable {
    public enum Kind: String {
        case source, repo
    }

    public struct Rule: Equatable {
        public let isOn: Bool
        public let kind: Kind
        public let name: String

        public init(isOn: Bool, kind: Kind, name: String) {
            self.isOn = isOn
            self.kind = kind
            self.name = name
        }
    }

    /// What decided a switch: a rule in the file, a built-in default, or nothing
    /// (on). The name is the key of the rule, which may be a parent's.
    public enum Reason: Equatable {
        case rule(String)
        case defaultRule(String)
        case none
    }

    /// The rules, in file order. A later rule for the same name replaces an earlier one.
    public let rules: [Rule]

    /// The built-in rules, which a rule of the same name in the file replaces.
    /// Headless runs come from scripts, and a `claude -p` run by hand already
    /// gets the terminal alert.
    public static let defaults: [String: Bool] = ["claude/headless": false]

    public init(rules: [Rule] = []) {
        self.rules = rules
    }

    // MARK: - Reading

    public static func parse(_ text: String) -> SourceRules {
        // "\r\n" is one Character in Swift, so a CRLF file splits on it too.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        return SourceRules(rules: lines.compactMap { parseLine(String($0)) })
    }

    /// One line, the way `__ada_sources_parse` reads it: state, kind, and the
    /// rest of the line as the name, trimmed.
    static func parseLine(_ raw: String) -> Rule? {
        var rest = Substring(raw).drop(while: isSpace)
        guard !rest.isEmpty, rest.first != "#" else { return nil }
        let state = rest.prefix(while: { !isSpace($0) })
        rest = rest.dropFirst(state.count).drop(while: isSpace)
        let kindText = rest.prefix(while: { !isSpace($0) })
        rest = rest.dropFirst(kindText.count).drop(while: isSpace)
        let name = String(rest.reversed().drop(while: isSpace).reversed())
        guard state == "on" || state == "off", let kind = Kind(rawValue: String(kindText)) else { return nil }
        switch kind {
        case .source:
            guard isValidSource(name) else { return nil }
        case .repo:
            guard !name.isEmpty, !name.contains("\t") else { return nil }
        }
        return Rule(isOn: state == "on", kind: kind, name: name)
    }

    private static func isSpace(_ character: Character) -> Bool {
        character.isWhitespace
    }

    /// `*`, or names of letters, digits, `.`, `_` and `-` joined by `/`, at most 100 long.
    public static func isValidSource(_ key: String) -> Bool {
        if key == "*" { return true }
        guard !key.isEmpty, key.count <= 100 else { return false }
        return key.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            guard let first = part.unicodeScalars.first, isAlphanumeric(first) else { return false }
            return part.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "." || $0 == "_" || $0 == "-" }
        }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
    }

    /// The rules file's rules; none when it is missing or not a file. A symlink
    /// is followed, as the script writes through one. Only the first 64 KB are
    /// read, so a runaway file can't stall the menu.
    public static func read(fileAt url: URL, maxBytes: Int = 1 << 16) -> SourceRules {
        let resolved = url.resolvingSymlinksInPath()
        guard isRegularFile(resolved), let handle = FileHandle(forReadingAtPath: resolved.path) else {
            return SourceRules()
        }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxBytes)
        return parse(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Lookup

    func lastRule(_ kind: Kind, _ name: String) -> Bool? {
        rules.last(where: { $0.kind == kind && $0.name == name })?.isOn
    }

    /// Whether alerts from a source show, and why.
    public func source(_ key: String) -> (isOn: Bool, reason: Reason) {
        var current = key
        while true {
            if let isOn = lastRule(.source, current) { return (isOn, .rule(current)) }
            if let isOn = Self.defaults[current] { return (isOn, .defaultRule(current)) }
            if current == "*" { break }
            if let slash = current.lastIndex(of: "/") {
                current = String(current[..<slash])
            } else {
                current = "*"
            }
        }
        return (true, .none)
    }

    /// Whether alerts from a project show; "" is an alert from outside any repo.
    public func repo(_ name: String) -> (isOn: Bool, reason: Reason) {
        for key in [name, "*"] where !key.isEmpty {
            if let isOn = lastRule(.repo, key) { return (isOn, .rule(key)) }
        }
        return (true, .none)
    }

    /// True when an alert from this source and project would show.
    public func allows(source: String, repo: String) -> Bool {
        guard self.source(source).isOn else { return false }
        return !hasRepoRules || self.repo(repo).isOn
    }

    public var hasRepoRules: Bool {
        rules.contains { $0.kind == .repo }
    }

    /// `off repo *`: only the projects turned on by name alert.
    public var onlyListedRepos: Bool {
        lastRule(.repo, "*") == false
    }

    /// Projects named by a rule, in file order, without `*` or repeats.
    public var namedRepos: [String] {
        var seen = Set<String>()
        return rules.compactMap { rule in
            guard rule.kind == .repo, rule.name != "*", seen.insert(rule.name).inserted else { return nil }
            return rule.name
        }
    }

    /// Sources named by a rule, in file order, without `*` or repeats.
    public var namedSources: [String] {
        var seen = Set<String>()
        return rules.compactMap { rule in
            guard rule.kind == .source, rule.name != "*", seen.insert(rule.name).inserted else { return nil }
            return rule.name
        }
    }
}
