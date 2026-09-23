#if canImport(AppKit)
import ADAAlertCore
import AppKit
import Foundation

final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private lazy var installDirectory: URL = InstallDirectory.resolve(
        environment: ProcessInfo.processInfo.environment,
        executableURL: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "ADA"
        item.button?.toolTip = "Agent Done Alert"

        let menu = NSMenu()
        menu.addItem(menuItem(title: "Test Alert", action: #selector(showTestAlert)))
        menu.addItem(menuItem(title: "Open ADA Folder", action: #selector(openFolder)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(title: "Quit ADA Menu Bar", action: #selector(quit)))
        item.menu = menu

        statusItem = item
    }

    @objc private func showTestAlert() {
        guard let launcher = InstallDirectory.launcher(in: installDirectory) else {
            presentError(
                "Missing launcher",
                informativeText: "Could not find an executable \(InstallDirectory.launcherPath) in \(installDirectory.path). Set ADA_HOME to your ada folder."
            )
            return
        }

        let process = Process()
        process.executableURL = launcher
        process.arguments = ["ada menu bar test", "1s", "0"]

        var environment = ProcessInfo.processInfo.environment
        environment["ADA_AUTO_CLOSE"] = environment["ADA_AUTO_CLOSE"] ?? "20"
        process.environment = environment

        do {
            try process.run()
        } catch {
            presentError("Could not launch alert", informativeText: error.localizedDescription)
        }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(installDirectory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func presentError(_ messageText: String, informativeText: String) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.runModal()
    }
}

switch Array(CommandLine.arguments.dropFirst()) {
case ["--check"]:
    print("ada-menubar native helper ok")
default:
    let app = NSApplication.shared
    let delegate = MenuBarAppDelegate()
    app.delegate = delegate
    app.run()
}
#else
import Foundation

fputs("ada-menubar requires macOS AppKit.\n", stderr)
exit(1)
#endif
