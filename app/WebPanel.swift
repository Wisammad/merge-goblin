//  WebPanel.swift — the WKWebView that hosts share/ui/panel.html.
//
//  The panel renders text that anyone who can open a pull request in a watched
//  repo gets to choose: PR titles, branch names, provider notes, doctor details.
//  panel.js is careful (everything goes through .textContent), but the web view
//  is configured on the assumption that one day it will not be.
//
//  So: a non-persistent data store, no popups, no file picker, no navigation
//  anywhere, and a Web Inspector only when a developer explicitly asks for one.

import AppKit
import WebKit
import os

final class WebPanel: NSObject, WKNavigationDelegate, WKUIDelegate {

    let webView: WKWebView
    private let bridge: Bridge
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "goblin", category: "panel")

    /// The one URL that is allowed to load. Everything else is cancelled.
    private let initialURL = URL(string: ResourceScheme.indexPath)!
    private var hasLoaded = false
    /// The one navigation the delegate will allow, armed immediately before the
    /// load that is supposed to produce it, and cleared the moment it is used.
    private var expectedNavigation: URL?
    /// The most recent push, replayed on didFinish. Without this, a state change
    /// that lands between load() and panel.js booting is simply lost, and the
    /// panel sits on "…" until the next file write.
    private var pendingPush: [String: Any]?

    init(bridge: Bridge) {
        self.bridge = bridge

        let configuration = WKWebViewConfiguration()
        // Nothing the panel does should outlive the popover: an XSS that manages
        // to write localStorage must not still be there on the next open.
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(ResourceScheme(), forURLScheme: ResourceScheme.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.suppressesIncrementalRendering = false
        configuration.userContentController.addScriptMessageHandler(
            bridge, contentWorld: .page, name: Bridge.handlerName)

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 620),
                            configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        // panel.css paints its own background for both appearances, but the web
        // view's own backdrop shows for the frame before CSS applies — white, in
        // dark mode, on every open. This is the public API for it; the usual
        // setValue(false, forKey: "drawsBackground") is a private KVC key that
        // raises NSUnknownKeyException, uncatchably, the release it goes away.
        webView.underPageBackgroundColor = .windowBackgroundColor

        // An inspectable web view is itself a bridge-access primitive: the
        // inspector's console can call window.webkit.messageHandlers.goblin
        // directly, from outside the CSP. Opt in per-launch, never by default.
        if #available(macOS 13.3, *) {
            webView.isInspectable = ProcessInfo.processInfo.environment["GOBLIN_DEV"] == "1"
        }
    }

    // MARK: - Loading

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        // Armed here, consumed by decidePolicyFor. Recognising the initial load by
        // "webView.url is still nil and the type is .other" looked right and was
        // not: WebKit has already published the provisional URL by the time the
        // policy delegate runs, so the one navigation we wanted got cancelled and
        // the panel was a blank rectangle.
        expectedNavigation = initialURL
        webView.load(URLRequest(url: initialURL))
    }

    /// Pushes state into the page. Queued until the document has finished loading.
    func push(_ payload: [String: Any]) {
        pendingPush = payload
        guard webView.url != nil, !webView.isLoading else { return }
        flushPush()
    }

    private func flushPush() {
        guard let payload = pendingPush else { return }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            log.error("state payload is not serialisable")
            pendingPush = nil
            return
        }
        pendingPush = nil
        // The guard matters: pushes start as soon as the popover exists, and
        // panel.js does not define __goblin until it has parsed. It queues
        // internally after that, so one push is never lost twice.
        let script = "window.__goblin && window.__goblin._state && window.__goblin._state(\(json));"
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                self?.log.error("state push failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Optional hook, for "Settings…" / "Set-up wizard…" / "Health check…" in the
    /// menu. `view` is one of settings|wizard|health and is a Swift-side literal,
    /// never anything a caller supplied, so it is safe to interpolate. The guard
    /// means a panel.js that has not implemented `_open` is simply unaffected.
    func request(view: String) {
        let script = "window.__goblin && window.__goblin._open && window.__goblin._open("
            + "{view:\"\(view)\"});"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url

        // The load we armed, and only that one.
        if let url, let expected = expectedNavigation, url == expected {
            expectedNavigation = nil
            decisionHandler(.allow)
            return
        }

        // A clicked https link is opened in the user's browser rather than
        // in here. This is still a cancelled navigation; the panel normally
        // routes links through the openURL verb, and this is the safety net for
        // any <a href> that slipped in.
        if action.navigationType == .linkActivated,
           let url, url.scheme?.lowercased() == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        log.error("""
            cancelled a navigation the panel is not allowed to make \
            (type \(action.navigationType.rawValue, privacy: .public), \
            scheme \(url?.scheme ?? "none", privacy: .public))
            """)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        flushPush()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log.error("panel failed to load: \(error.localizedDescription, privacy: .public)")
        hasLoaded = false
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        log.error("panel failed to load: \(error.localizedDescription, privacy: .public)")
        hasLoaded = false
    }

    /// A web content crash must not leave a blank popover forever.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("panel web content terminated; reloading")
        hasLoaded = false
        loadIfNeeded()
    }

    // MARK: - WKUIDelegate

    /// No popups. window.open() has no legitimate use here and a new WKWebView
    /// would not inherit any of this configuration.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    /// No file picker. An <input type=file> dialog is a filesystem reconnaissance
    /// primitive — the returned path alone tells you the username and layout —
    /// and the panel never needs to upload anything.
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        log.error("refused a file picker request from the panel")
        completionHandler(nil)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Merge Goblin"
        // The message is attacker-influencable text, so it goes in informativeText
        // (plain, never parsed) and is truncated.
        alert.informativeText = String(message.prefix(500))
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        // The panel has its own in-page confirm (confirmAsk); a native one would
        // be a second, inconsistent style of question. Fail closed.
        completionHandler(false)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        completionHandler(nil)
    }
}
