import AppKit
import Foundation
import SwiftUI
import WebKit

/// One WebView is reused for all remote windows. tmux and SSH never enter this layer.
@MainActor
final class RemoteTerminalView: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private let allowedURL: URL
    private var ready = false
    private var stopped = false
    private var columns = 80
    private var rows = 24
    private(set) var selected: RemoteWindow?
    private var awaitingSnapshot = false
    private var selectionRevision = 0

    var onSelect: ((RemoteWindow, Int, Int) -> Void)?
    var onInput: ((RemoteWindow, Data) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController = WKUserContentController()
        let folder = Bundle.main.resourceURL!.appendingPathComponent("Web", isDirectory: true)
        allowedURL = folder.appendingPathComponent("terminal.html")
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakRemoteHandler(self), name: "terminal")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.underPageBackgroundColor = NSColor(calibratedWhite: 30.0 / 255.0, alpha: 1)
        if #available(macOS 13.3, *) { webView.isInspectable = false }
        webView.loadFileURL(allowedURL, allowingReadAccessTo: folder)
    }

    func select(_ window: RemoteWindow) {
        guard !stopped else { return }
        selected = window
        awaitingSnapshot = true
        selectionRevision += 1
        let revision = selectionRevision
        if ready {
            webView.evaluateJavaScript("window.privateTerm.clear(); window.privateTerm.fitAndFocus()") { [weak self] result, _ in
                DispatchQueue.main.async {
                    guard let self, !self.stopped, self.selectionRevision == revision,
                          self.selected?.id == window.id else { return }
                    if let size = result as? [String: Any] {
                        self.columns = min(max(size["cols"] as? Int ?? self.columns, 2), 1000)
                        self.rows = min(max(size["rows"] as? Int ?? self.rows, 2), 1000)
                    }
                    self.onSelect?(window, self.columns, self.rows)
                }
            }
        }
    }

    func append(_ bytes: Data, hostID: String, paneID: String) {
        guard ready, selected?.hostID == hostID, selected?.paneID == paneID else { return }
        // The capture includes output produced before its command reply.
        if !awaitingSnapshot { render(bytes) }
    }

    func snapshot(_ bytes: Data, hostID: String, paneID: String) {
        guard ready, selected?.hostID == hostID, selected?.paneID == paneID else { return }
        awaitingSnapshot = false
        webView.evaluateJavaScript("window.privateTerm.clear()", completionHandler: nil)
        render(bytes)
    }

    func focus() {
        guard ready else { return }
        webView.evaluateJavaScript("window.privateTerm.fitAndFocus()", completionHandler: nil)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private func render(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        // Terminal bytes are encoded; no remote data is interpolated into JavaScript.
        let js = "window.privateTerm.receiveBase64('" + bytes.base64EncodedString() + "', null)"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !stopped, message.name == "terminal", message.frameInfo.isMainFrame,
              let payload = message.body as? [String: Any], let kind = payload["type"] as? String else { return }
        if kind == "ready" {
            guard !ready else { return }
            ready = true
            columns = min(max(payload["cols"] as? Int ?? 80, 2), 1000)
            rows = min(max(payload["rows"] as? Int ?? 24, 2), 1000)
            if let selected { select(selected) }
        } else if let selected, kind == "input", let text = payload["data"] as? String,
                  text.utf8.count <= 1024 * 1024 {
            onInput?(selected, Data(text.utf8))
        } else if let selected, kind == "binary", let base64 = payload["data"] as? String,
                  base64.count <= 2 * 1024 * 1024, let bytes = Data(base64Encoded: base64) {
            onInput?(selected, bytes)
        } else if kind == "resize" {
            let cols = min(max(payload["cols"] as? Int ?? 80, 2), 1000)
            let lines = min(max(payload["rows"] as? Int ?? 24, 2), 1000)
            columns = cols
            rows = lines
            if let selected {
                awaitingSnapshot = true
                onSelect?(selected, cols, lines)
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame != false else { decisionHandler(.cancel); return }
        let url = action.request.url
        decisionHandler(url?.isFileURL == true && url?.standardizedFileURL == allowedURL.standardizedFileURL ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}

private final class WeakRemoteHandler: NSObject, WKScriptMessageHandler {
    weak var view: RemoteTerminalView?
    init(_ view: RemoteTerminalView) { self.view = view }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { view?.userContentController(controller, didReceive: message) }
    }
}

struct RemoteTerminalSurface: NSViewRepresentable {
    let terminal: RemoteTerminalView
    func makeNSView(context: Context) -> WKWebView { terminal.webView }
    func updateNSView(_ view: WKWebView, context: Context) { }
}
