#if canImport(AppKit) && canImport(WebKit)
import AppKit
import Foundation
import ADAAlertCore
import WebKit

final class AlertWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

final class AlertAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler {
    private let alertURL: URL
    private let signalBaseURL: URL?
    private var window: NSWindow?
    private var webView: WKWebView?
    private let preferences = UserDefaults(suiteName: SnoozePreference.suiteName) ?? .standard

    init(alertURL: URL) {
        self.alertURL = alertURL
        self.signalBaseURL = AlertSignalURL.baseURL(from: alertURL)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)

        let window = AlertWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "Command Finished"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1)
        window.collectionBehavior = [.moveToActiveSpace]

        let userContentController = WKUserContentController()
        userContentController.addUserScript(WKUserScript(
            source: nativeCloseBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        userContentController.addUserScript(WKUserScript(
            source: SnoozePreference.bootstrapScript(pinned: SnoozePreference.isPinned(in: preferences)),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        userContentController.add(self, name: "adaClose")
        userContentController.add(self, name: "adaSignal")
        userContentController.add(self, name: "adaOpen")
        userContentController.add(self, name: SnoozePreference.messageHandlerName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: window.contentView?.bounds ?? frame, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")

        window.contentView = webView
        self.window = window
        self.webView = webView

        loadAlert(in: webView)

        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        webView.window?.makeFirstResponder(webView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "adaClose":
            NSApp.terminate(nil)
        case "adaSignal":
            if let path = message.body as? String {
                sendSignal(path)
            }
        case "adaOpen":
            // Open external links (e.g. the feedback link) in the user's default
            // browser rather than navigating the alert's own WebView away. The
            // http(s)-only rule lives in ADAAlertCore, where it is unit-tested.
            if let url = ExternalLink.openableURL(from: message.body) {
                NSWorkspace.shared.open(url)
            }
        case SnoozePreference.messageHandlerName:
            // "Pin open" on the snooze options: remembered for every later alert.
            if let pinned = SnoozePreference.pinned(fromMessageBody: message.body) {
                SnoozePreference.setPinned(pinned, in: preferences)
            }
        default:
            break
        }
    }

    private func loadAlert(in webView: WKWebView) {
        if alertURL.isFileURL {
            let readAccess = URL(fileURLWithPath: alertURL.path).deletingLastPathComponent()
            webView.loadFileURL(alertURL, allowingReadAccessTo: readAccess)
        } else {
            webView.load(URLRequest(url: alertURL))
        }
    }

    private func sendSignal(_ path: String) {
        guard let signalBaseURL else { return }
        guard let url = AlertSignalURL.signalURL(baseURL: signalBaseURL, path: path) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.75

        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + .milliseconds(750))
    }
}

switch AlertCommandLine.parse(Array(CommandLine.arguments.dropFirst())) {
case .success(.check):
    print("ada-alert native helper ok")
case .success(.help):
    print(AlertCommandLine.usage)
case .success(.show(let url)):
    let app = NSApplication.shared
    let delegate = AlertAppDelegate(alertURL: url)
    app.delegate = delegate
    app.run()
case .failure(let error):
    fputs(error.message + "\n", stderr)
    exit(2)
}

#else
import Foundation

fputs("ada-alert requires macOS AppKit/WebKit.\n", stderr)
exit(1)
#endif
