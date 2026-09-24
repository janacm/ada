#if canImport(AppKit)
import ADAAlertCore
import AppKit
import Foundation

/// What the menu shows and where the scripts it runs live. Everything but the
/// integration report is read from disk each time the menu opens; the report
/// runs `lib/ada-status.sh`, which takes about half a second (mostly asking
/// opencode for its config dir), so it runs in the background.
struct MenuBarContext {
    let environment: [String: String]
    let installDirectory: URL
    let paths: StatePaths

    static func current() -> MenuBarContext {
        let environment = ProcessInfo.processInfo.environment
        return MenuBarContext(
            environment: environment,
            installDirectory: InstallDirectory.resolve(
                environment: environment,
                executableURL: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            ),
            paths: StatePaths.resolve(environment: environment)
        )
    }

    func input(integrations: [IntegrationStatus]?, now: Date = Date()) -> MenuInput {
        let history = AlertHistory.read(fileAt: paths.historyFile)
        let muted = MuteList.read(directory: paths.muteDirectory,
                                  maxAge: MuteList.maxAge(environment: environment),
                                  now: now, history: history)
        return MenuInput(pause: PauseState.read(fileAt: paths.pauseFile, now: now), history: history,
                         muted: muted, integrations: integrations, now: now, calendar: .current)
    }

    struct ScriptResult {
        let status: Int32
        let output: String
        let errors: String
    }

    enum ScriptError: Error {
        case missing(String)
        case failed(String)
    }

    /// Runs a script from the install directory and waits for it. The working
    /// directory is TMPDIR, because a LaunchAgent starts in `/`.
    func run(_ relativePath: String, _ arguments: [String], extra: [String: String] = [:],
             timeout: TimeInterval = 15) -> Result<ScriptResult, ScriptError> {
        guard let script = InstallDirectory.script(relativePath, in: installDirectory) else {
            return .failure(.missing("\(installDirectory.path)/\(relativePath)"))
        }
        let process = Process()
        process.executableURL = script
        process.arguments = arguments
        process.environment = ChildEnvironment.make(base: environment, paths: paths, extra: extra)
        process.currentDirectoryURL = paths.tempDirectory
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        // Set before run(): a script that exits at once must still signal.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
        // Drain both pipes while waiting, so neither a chatty script (a full
        // pipe blocks it) nor a hung one (a read never ends) outlives the timeout.
        let out = PipeReader(output), err = PipeReader(errors)
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return .failure(.failed("\(relativePath) did not finish within \(Int(timeout)) seconds"))
        }
        return .success(ScriptResult(status: process.terminationStatus,
                                     output: out.text(waitingUpTo: 2),
                                     errors: err.text(waitingUpTo: 2)))
    }

    /// The integration report. A LaunchAgent may not look inside ~/Documents,
    /// so the report skips existence checks under $HOME and /Volumes.
    func integrations() -> [IntegrationStatus] {
        guard case let .success(result) = run(InstallDirectory.statusScriptPath, [],
                                              extra: ["ADA_STATUS_SKIP_PROTECTED": "1"]) else {
            return [IntegrationStatus(id: "status", state: .warn, name: "Integrations",
                                      detail: "can't run \(InstallDirectory.statusScriptPath)")]
        }
        return IntegrationStatus.parse(result.output)
    }
}

/// Reads a pipe to its end on a background queue. A grandchild that inherited
/// the pipe can hold it open after the script exits, so `text` waits only so long.
final class PipeReader {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            self.data = handle.readDataToEndOfFile()
            self.done.signal()
        }
    }

    func text(waitingUpTo seconds: Double) -> String {
        guard done.wait(timeout: .now() + seconds) == .success else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A menu item's action, carried as an object in `representedObject`.
final class ActionBox: NSObject {
    let action: MenuAction
    init(_ action: MenuAction) { self.action = action }
}

final class MenuBarAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let context: MenuBarContext
    private let lock: SingleInstanceLock?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private weak var integrationsMenu: NSMenu?
    private var menuIsOpen = false

    private var integrations: [IntegrationStatus]?
    private var integrationsCheckedAt: Date?
    private var integrationsRunning = false

    private var tick: Timer?
    private var pauseEnd: Timer?
    private var relaunch: RelaunchWatcher?
    private var watchedExecutable: String?

    init(context: MenuBarContext, lock: SingleInstanceLock?) {
        self.context = context
        self.lock = lock
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon()

        // Started by launchd: watch the binary at the path launchd runs, so a
        // `brew upgrade` or a re-stage restarts us on the new one.
        if RelaunchWatcher.launchedByLaunchd(environment: context.environment) {
            let path = CommandLine.arguments[0]
            if path.hasPrefix("/"), let identity = ExecutableIdentity.of(path: path) {
                watchedExecutable = path
                relaunch = RelaunchWatcher(original: identity)
            }
        }

        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.onTick() }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer

        refreshIntegrations()
    }

    private func onTick() {
        updateIcon()
        if var watcher = relaunch, let path = watchedExecutable {
            let decision = watcher.check(ExecutableIdentity.of(path: path))
            relaunch = watcher
            switch decision {
            case .keepRunning: break
            case .relaunch: exit(RelaunchWatcher.relaunchExitCode)
            case .exit: exit(0)
            }
        }
    }

    // MARK: - Icon

    private func updateIcon() {
        let now = Date()
        let pause = PauseState.read(fileAt: context.paths.pauseFile, now: now)
        if let button = statusItem?.button {
            let symbol = MenuModel.statusSymbol(for: pause)
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ADA") {
                image.isTemplate = true
                button.image = image
                button.title = ""
            } else {
                button.image = nil
                button.title = pause.isPaused ? "ADA ⏸" : "ADA"
            }
            button.toolTip = "Agent Done Alert: \(pause.title(now: now, calendar: .current))"
        }
        // Flip the icon back the moment a timed pause ends, not up to 30s later.
        pauseEnd?.invalidate()
        pauseEnd = nil
        if case let .paused(until: end?) = pause {
            let timer = Timer(fire: end.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
                self?.updateIcon()
            }
            RunLoop.main.add(timer, forMode: .common)
            pauseEnd = timer
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuildMenu()
        if let checked = integrationsCheckedAt, Date().timeIntervalSince(checked) < 60 { return }
        refreshIntegrations()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu { menuIsOpen = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { menuIsOpen = false }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        integrationsMenu = nil
        for item in makeItems(MenuModel.build(context.input(integrations: integrations))) {
            menu.addItem(item)
        }
    }

    private func makeItems(_ entries: [MenuEntry]) -> [NSMenuItem] {
        entries.map { entry in
            switch entry {
            case .separator:
                return NSMenuItem.separator()
            case let .info(title, symbol):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = image(symbol)
                return item
            case let .action(title, action, symbol):
                let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ActionBox(action)
                item.image = image(symbol)
                return item
            case let .submenu(title, children, symbol):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: title)
                for child in makeItems(children) { submenu.addItem(child) }
                item.submenu = submenu
                item.image = image(symbol)
                if title == "Integrations" { integrationsMenu = submenu }
                return item
            }
        }
    }

    private func image(_ symbol: String?) -> NSImage? {
        guard let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        image.isTemplate = true
        return image
    }

    private func refreshIntegrations() {
        guard !integrationsRunning else { return }
        integrationsRunning = true
        let context = self.context
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = context.integrations()
            DispatchQueue.main.async {
                guard let self else { return }
                self.integrations = report
                self.integrationsCheckedAt = Date()
                self.integrationsRunning = false
                // Update the open menu in place rather than making you reopen it.
                if self.menuIsOpen, let submenu = self.integrationsMenu {
                    submenu.removeAllItems()
                    let entries = MenuModel.integrationEntries(self.context.input(integrations: report))
                    for item in self.makeItems(entries) { submenu.addItem(item) }
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func choose(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        switch box.action {
        case let .pause(minutes):
            runScript(InstallDirectory.pauseScriptPath, ["\(minutes)"])
        case let .pauseUntil(date):
            runScript(InstallDirectory.pauseScriptPath, ["until", "\(Int(date.timeIntervalSince1970))"])
        case .pauseUntilResumed:
            runScript(InstallDirectory.pauseScriptPath, ["forever"])
        case .resume:
            runScript(InstallDirectory.pauseScriptPath, ["resume"])
        case let .open(target):
            open(target)
        case .clearHistory:
            runScript(InstallDirectory.historyScriptPath, ["clear"])
        case let .unmute(key):
            runScript(InstallDirectory.muteScriptPath, ["clear", key])
        case .unmuteAll:
            runScript(InstallDirectory.muteScriptPath, ["clear"])
        case .setUp:
            setUp()
        case .testAlert:
            showTestAlert()
        case .openFolder:
            NSWorkspace.shared.open(context.installDirectory)
        case .quit:
            NSApp.terminate(nil)
        }
    }

    /// Runs a state-changing script off the main thread, then refreshes the icon.
    private func runScript(_ relativePath: String, _ arguments: [String]) {
        let context = self.context
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = context.run(relativePath, arguments)
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateIcon()
                switch result {
                case let .success(done) where done.status != 0:
                    self.presentError("\(relativePath) failed", informativeText: done.errors.isEmpty ? "exit \(done.status)" : done.errors)
                case let .failure(.missing(path)):
                    self.presentError("Missing script", informativeText: "Could not find an executable \(path). Set ADA_HOME to your ada folder.")
                case let .failure(.failed(reason)):
                    self.presentError("\(relativePath) failed", informativeText: reason)
                default:
                    break
                }
            }
        }
    }

    private func open(_ target: ClickTarget) {
        switch target {
        case let .url(url):
            NSWorkspace.shared.open(url)
        case let .application(bundleIdentifier):
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                presentError("App not found", informativeText: "No app with bundle id \(bundleIdentifier) is installed.")
                return
            }
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func showTestAlert() {
        guard let launcher = InstallDirectory.launcher(in: context.installDirectory) else {
            presentError(
                "Missing launcher",
                informativeText: "Could not find an executable \(InstallDirectory.launcherPath) in \(context.installDirectory.path). Set ADA_HOME to your ada folder."
            )
            return
        }

        let process = Process()
        process.executableURL = launcher
        process.arguments = ["ada menu bar test", "1s", "0"]
        // A test alert is one you asked for, so it shows even while paused.
        process.environment = ChildEnvironment.make(
            base: context.environment, paths: context.paths,
            extra: ["ADA_AUTO_CLOSE": context.environment["ADA_AUTO_CLOSE"] ?? "20", "ADA_IGNORE_PAUSE": "1"]
        )
        process.currentDirectoryURL = context.paths.tempDirectory

        do {
            try process.run()
        } catch {
            presentError("Could not launch alert", informativeText: error.localizedDescription)
        }
    }

    /// Hands the installer to Terminal as a .command file, so it runs with
    /// Terminal's folder access rather than this process's.
    private func setUp() {
        let stage = StageInfo.read(in: context.installDirectory)
        guard let installer = SetupCommand.installerPath(installDirectory: context.installDirectory, stageInfo: stage,
                                                         fileExists: { FileManager.default.fileExists(atPath: $0) }) else {
            presentError("Installer not found", informativeText: "No ada-install.sh next to \(context.installDirectory.path), and no record of where this copy was staged from.")
            return
        }
        let command = context.paths.tempDirectory.appendingPathComponent("ada-setup.command")
        do {
            try SetupCommand.script(installer: installer).write(to: command, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        } catch {
            presentError("Could not start the installer", informativeText: error.localizedDescription)
            return
        }
        NSWorkspace.shared.open(command)
        integrationsCheckedAt = nil
    }

    private func presentError(_ messageText: String, informativeText: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.runModal()
    }
}

switch MenuBarCommand.parse(Array(CommandLine.arguments.dropFirst())) {
case .check:
    print("ada-menubar native helper ok")
case .help:
    print(MenuBarCommand.usage)
case let .unknown(arguments):
    fputs("ada-menubar: unknown arguments: \(arguments)\n\(MenuBarCommand.usage)\n", stderr)
    exit(2)
case .printMenu:
    let context = MenuBarContext.current()
    print(MenuModel.render(MenuModel.build(context.input(integrations: context.integrations()))))
case .run:
    let context = MenuBarContext.current()
    var held: SingleInstanceLock?
    switch SingleInstanceLock.acquire(at: context.paths.lockFile) {
    case let .acquired(lock):
        held = lock
    case .heldElsewhere:
        fputs("ada-menubar: another ADA menu bar is already running\n", stderr)
        exit(0)
    case .unavailable:
        break
    }
    let app = NSApplication.shared
    let delegate = MenuBarAppDelegate(context: context, lock: held)
    app.delegate = delegate
    app.run()
}
#else
import Foundation

fputs("ada-menubar requires macOS AppKit.\n", stderr)
exit(1)
#endif
