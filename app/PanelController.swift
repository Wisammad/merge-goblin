//  PanelController.swift — the popover the panel lives in.
//
//  Two non-obvious pieces:
//
//  1. `.transient` is supposed to close the popover when you click elsewhere, and
//     mostly does. It misses outside clicks on a second display, and clicks that
//     land in another application's window on the same display, which leaves the
//     panel floating over whatever you switched to. A global mouse-down monitor
//     closes it for real. Global monitors only see events destined for OTHER
//     applications, so a click on our own status item does not reach it and the
//     toggle logic keeps working.
//
//  2. The web view is created on first open, not at launch: WebKit spawns two
//     helper processes, and paying ~40 MB and a spinning fan for someone who
//     never opens the panel is rude for a login item. It is then pre-warmed three
//     seconds after launch, so the first real click is instant anyway.

import AppKit

final class PanelController: NSObject, NSPopoverDelegate {

    private let bridge: Bridge
    private let popover = NSPopover()
    private var web: WebPanel?
    private var clickMonitor: Any?
    /// Called when the panel opens, so the store can pick up the facts that no
    /// file write signals (launchd state, active gh account).
    var onWillOpen: (() -> Void)?

    private static let contentSize = NSSize(width: 420, height: 620)

    init(bridge: Bridge) {
        self.bridge = bridge
        super.init()
        popover.behavior = .transient
        // No animation: a status-item popover that fades in feels slow, and the
        // fade is the window in which a second click double-toggles it.
        popover.animates = false
        popover.delegate = self
        popover.contentSize = PanelController.contentSize
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    var isShown: Bool { popover.isShown }

    // MARK: - Showing

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        onWillOpen?()
        let panel = makeWebPanelIfNeeded()
        panel.loadIfNeeded()
        push(StateStore.shared.state)

        // Anchored to the button's bounds with .minY: the popover hangs from the
        // bottom edge of the status item, which is where macOS puts menus.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // ACTIVATE THE APP. This is not optional and it is not cosmetic.
        //
        // We are an .accessory (LSUIElement) app, so showing a popover does not
        // make us the active application. `makeKey()` on a window belonging to an
        // INACTIVE app does not reliably confer key status, and a WKWebView that is
        // not in the active app does not deliver clicks to its form controls —
        // checkboxes, selects and buttons all just sit there. Scrolling still works,
        // because the scroll wheel needs neither key status nor activation, which is
        // exactly what the symptom looked like: a panel you can read and scroll but
        // cannot operate.
        //
        // Order matters: activate first, then take key, then first responder.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        panel.webView.window?.makeFirstResponder(panel.webView)
        startClickMonitor()
    }

    func close() {
        popover.performClose(nil)
    }

    /// Warms WebKit and the panel document so the first click is not a 400ms
    /// white rectangle. Three seconds after launch: long enough that it never
    /// competes with login, short enough that it is always ready in practice.
    func prewarm(after delay: TimeInterval = 3) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.web == nil else { return }
            let panel = self.makeWebPanelIfNeeded()
            panel.loadIfNeeded()
            self.push(StateStore.shared.state)
        }
    }

    func push(_ state: GoblinState) {
        web?.push(state.pushPayload())
    }

    /// Asks the panel to show a particular section. Advisory: panel.js decides for
    /// itself whether the wizard is due (it asks the `wizardState` verb), so this
    /// is a hint through an optional hook and a no-op if the hook is absent.
    func request(view: MenuController.PanelView) {
        web?.request(view: view.rawValue)
    }

    // MARK: - Construction

    private func makeWebPanelIfNeeded() -> WebPanel {
        if let web { return web }
        let panel = WebPanel(bridge: bridge)
        let controller = NSViewController()
        let container = NSView(frame: NSRect(origin: .zero, size: PanelController.contentSize))
        panel.webView.frame = container.bounds
        panel.webView.autoresizingMask = [.width, .height]
        container.addSubview(panel.webView)
        controller.view = container
        popover.contentViewController = controller
        web = panel
        return panel
    }

    // MARK: - Outside clicks

    private func startClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.close()
        }
    }

    private func stopClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        stopClickMonitor()
    }
}
