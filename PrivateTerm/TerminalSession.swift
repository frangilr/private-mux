import AppKit
import Foundation
import WebKit
import Combine
import SwiftUI

/// One clickable sidebar entry, one persistent WebView, and one independent PTY.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    @Published var title: String
    @Published private(set) var hasExited = false

    let webView: WKWebView
    private let allowedURL: URL
    private var process: PTYProcess?
    private var isReady = false
    private var isStopped = false
    private var nextOutputID = 0
    private var outstandingOutputID: Int?

    init(title: String) {
        self.title = title
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // A fresh content controller per tab isolates native message handlers.
        config.userContentController = WKUserContentController()
        let bundleFolder = Bundle.main.resourceURL!.appendingPathComponent("Web", isDirectory: true)
        allowedURL = bundleFolder.appendingPathComponent("terminal.html")
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakTerminalHandler(self), name: "terminal")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.underPageBackgroundColor = NSColor(calibratedWhite: 30.0 / 255.0, alpha: 1.0)
        if #available(macOS 13.3, *) { webView.isInspectable = false }
        webView.loadFileURL(allowedURL, allowingReadAccessTo: bundleFolder)
    }

    func fitAndFocus() {
        guard !isStopped else { return }
        webView.evaluateJavaScript("window.privateTerm && window.privateTerm.fitAndFocus()", completionHandler: nil)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        process?.onOutput = nil
        process?.onExit = nil
        process?.stop(terminateChild: !hasExited)
        process = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !isStopped, message.name == "terminal", message.frameInfo.isMainFrame,
              let payload = message.body as? [String: Any], let kind = payload["type"] as? String
        else { return }

        switch kind {
        case "ready":
            guard !isReady else { return }
            isReady = true
            let cols = clampDimension(payload["cols"])
            let rows = clampDimension(payload["rows"])
            guard let spawned = PTYProcess(columns: cols, rows: rows) else {
                showStatus("Could not launch /bin/zsh in a pseudo-terminal.")
                return
            }
            process = spawned
            spawned.onOutput = { [weak self] bytes in
                DispatchQueue.main.async { self?.sendOutput(bytes, requiresAcknowledgement: true) }
            }
            spawned.onExit = { [weak self] in
                guard let self else { return }
                self.hasExited = true
                self.process?.stop(terminateChild: false)
                self.showStatus("\r\n[Shell exited. Close this tab to finish.]\r\n")
            }
            spawned.beginReading()
            fitAndFocus()

        case "input":
            guard let text = payload["data"] as? String, text.utf8.count <= 1024 * 1024 else { return }
            process?.send(Data(text.utf8))

        case "binary":
            guard let string = payload["data"] as? String, string.count <= 2 * 1024 * 1024,
                  let bytes = Data(base64Encoded: string) else { return }
            process?.send(bytes)

        case "resize":
            process?.resize(columns: clampDimension(payload["cols"]), rows: clampDimension(payload["rows"]))

        case "output-drained":
            guard let id = payload["id"] as? Int, id == outstandingOutputID else { return }
            outstandingOutputID = nil
            process?.beginReading()

        default:
            break
        }
    }

    private func clampDimension(_ value: Any?) -> Int {
        let n = value as? Int ?? 80
        return min(max(n, 2), 1000)
    }

    private func showStatus(_ message: String) {
        sendOutput(Data(message.utf8), requiresAcknowledgement: false)
    }

    private func sendOutput(_ bytes: Data, requiresAcknowledgement: Bool) {
        guard !isStopped, !bytes.isEmpty else { return }
        let id: Int?
        if requiresAcknowledgement {
            precondition(outstandingOutputID == nil)
            nextOutputID += 1
            id = nextOutputID
            outstandingOutputID = id
        } else {
            id = nil
        }
        // Base64 and the native integer never interpret terminal bytes as JS.
        let js = "window.privateTerm && window.privateTerm.receiveBase64('" + bytes.base64EncodedString() + "', " + (id.map(String.init) ?? "null") + ")"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // Only the bundled terminal.html is a valid top-level page. In particular
    // links printed by a remote server cannot turn this view into a web browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.cancel)
            return
        }
        let url = navigationAction.request.url
        decisionHandler(url?.isFileURL == true && url?.standardizedFileURL == allowedURL.standardizedFileURL ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}

/// Prevent a WKWebView -> script handler -> TerminalSession -> WKWebView cycle.
private final class WeakTerminalHandler: NSObject, WKScriptMessageHandler {
    weak var session: TerminalSession?
    init(_ session: TerminalSession) { self.session = session }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // WKWebView messages arrive on the main thread.
        MainActor.assumeIsolated { session?.userContentController(controller, didReceive: message) }
    }
}

struct TerminalSurface: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
}
