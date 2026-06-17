#if canImport(AppKit)
import AppKit
import Foundation

final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private lazy var scriptDirectory: URL = resolveScriptDirectory()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "IYF"
        item.button?.toolTip = "In Your Face"

        let menu = NSMenu()
        menu.addItem(menuItem(title: "Test Alert", action: #selector(showTestAlert)))
        menu.addItem(menuItem(title: "Open IYF Folder", action: #selector(openFolder)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(title: "Quit IYF Menu Bar", action: #selector(quit)))
        item.menu = menu

        statusItem = item
    }

    @objc private func showTestAlert() {
        let launcher = scriptDirectory.appendingPathComponent("iyf-show-alert.sh")
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else {
            presentError("Missing launcher", informativeText: "Could not find executable iyf-show-alert.sh next to iyf-menubar or in IYF_HOME.")
            return
        }

        let process = Process()
        process.executableURL = launcher
        process.arguments = ["iyf menu bar test", "1s", "0"]

        var environment = ProcessInfo.processInfo.environment
        environment["IYF_AUTO_CLOSE"] = environment["IYF_AUTO_CLOSE"] ?? "20"
        process.environment = environment

        do {
            try process.run()
        } catch {
            presentError("Could not launch alert", informativeText: error.localizedDescription)
        }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(scriptDirectory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func resolveScriptDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let iyfHome = environment["IYF_HOME"], !iyfHome.isEmpty {
            return URL(fileURLWithPath: iyfHome, isDirectory: true)
        }

        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var directory = executableURL.deletingLastPathComponent()
        if directory.lastPathComponent == "MacOS" {
            directory = directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        return directory
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
    print("iyf-menubar native helper ok")
default:
    let app = NSApplication.shared
    let delegate = MenuBarAppDelegate()
    app.delegate = delegate
    app.run()
}
#else
import Foundation

fputs("iyf-menubar requires macOS AppKit.\n", stderr)
exit(1)
#endif
