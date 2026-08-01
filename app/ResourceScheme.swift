//  ResourceScheme.swift — serves the panel to the WKWebView over goblin://.
//
//  Why a custom scheme instead of file:// —
//
//    * a file:// document has an OPAQUE origin, which makes the panel's CSP
//      `script-src 'self'` meaningless: 'self' matches nothing, so the policy
//      protects nothing. goblin://panel is a real, unique, non-opaque origin, so
//      'self' means "the five files below and nothing else".
//    * loadFileURL(_:allowingReadAccessTo:) hands the web content a directory
//      read primitive. An XSS in the panel — a PR title is attacker-chosen text —
//      could then read anything under that directory. There is no reason to grant
//      that when the panel needs exactly five files.
//
//  Path traversal is not defended against here; it is UNREPRESENTABLE. The map
//  below is name -> mime, the lookup is by exact name, and anything else 404s
//  before touching the filesystem. There is no string concatenation of a
//  request-supplied component into a path.

import Foundation
import WebKit
import os

final class ResourceScheme: NSObject, WKURLSchemeHandler {

    static let scheme = "goblin"
    static let host = "panel"
    static let indexPath = "goblin://panel/panel.html"

    /// The complete set of servable resources. Adding a file here is a deliberate
    /// act; there is no "everything in this directory" mode.
    private static let servable: [String: String] = [
        "panel.html": "text/html; charset=utf-8",
        "panel.css":  "text/css; charset=utf-8",
        "panel.js":   "text/javascript; charset=utf-8",
        "wizard.js":  "text/javascript; charset=utf-8",
        "goblin.svg": "image/svg+xml",
    ]

    /// Sent as a real header rather than relying on panel.html's <meta>. A header
    /// is applied by the loader before the document is parsed, cannot be
    /// displaced by injected markup appearing above it, and covers the .css/.js
    /// subresources too.
    private static let csp = [
        "default-src 'none'",
        "script-src 'self'",
        "style-src 'self'",
        "img-src 'self' data:",
        "connect-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'none'",
    ].joined(separator: "; ")

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "goblin", category: "scheme")

    /// The bundle's ui directory. Resolved once; a nil here means the bundle was
    /// assembled wrong and every request 404s, which is at least visible.
    private static let uiDirectory: URL? =
        Bundle.main.resourceURL?.appendingPathComponent("ui", isDirectory: true)

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            fail(task, url: URL(string: "goblin://panel/")!, status: 400)
            return
        }

        guard url.host == ResourceScheme.host else {
            log.error("refused a goblin:// request with an unexpected host")
            fail(task, url: url, status: 404)
            return
        }

        // lastPathComponent, then an exact map lookup. "../../etc/passwd" has a
        // lastPathComponent of "passwd", which is simply not in the map.
        let name = url.lastPathComponent
        guard let mime = ResourceScheme.servable[name],
              let directory = ResourceScheme.uiDirectory else {
            log.error("refused a goblin:// request for a resource that is not servable")
            fail(task, url: url, status: 404)
            return
        }

        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
            log.error("\(name, privacy: .public) is missing from the app bundle")
            fail(task, url: url, status: 404)
            return
        }

        let headers = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "Content-Security-Policy": ResourceScheme.csp,
            "X-Content-Type-Options": "nosniff",
            // The bundle is the source of truth and it changes on rebuild; a
            // cached panel.js after `goblin app rebuild` is a support call.
            "Cache-Control": "no-store",
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                             httpVersion: "HTTP/1.1", headerFields: headers) else {
            fail(task, url: url, status: 500)
            return
        }

        // Everything above is synchronous, so the task cannot have been stopped
        // between start and here. That matters: calling didReceive on a stopped
        // WKURLSchemeTask raises an Objective-C exception, which is not catchable.
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Nothing to cancel: every response is produced synchronously in start.
    }

    private func fail(_ task: WKURLSchemeTask, url: URL, status: Int) {
        let headers = [
            "Content-Type": "text/plain; charset=utf-8",
            "Content-Security-Policy": ResourceScheme.csp,
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-store",
        ]
        if let response = HTTPURLResponse(url: url, statusCode: status,
                                          httpVersion: "HTTP/1.1", headerFields: headers) {
            task.didReceive(response)
            task.didReceive(Data())
            task.didFinish()
        } else {
            task.didFailWithError(URLError(.badURL))
        }
    }
}
