//  AppDelegate.swift — lifecycle and wiring.
//
//  The single-instance guard is not defensive programming, it is the expected
//  case: the login item (a LaunchAgent) starts one copy at login, and then
//  double-clicking Merge Goblin.app in ~/Applications — or Spotlight, or `open
//  -a` — starts a second. Two copies means two status items, two file watchers,
//  and a user who cannot tell which goblin they are talking to.

import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: StatusItemController?
    private var menuController: MenuController?
    private var panelController: PanelController?
    private var bridge: Bridge?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "goblin", category: "app")

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfAlreadyRunning() else { return }

        let bridge = Bridge()
        let panel = PanelController(bridge: bridge)
        let menu = MenuController()
        let status = StatusItemController()

        self.bridge = bridge
        self.panelController = panel
        self.menuController = menu
        self.statusItem = status

        // Left click: the panel. Right click (or ctrl-click): the menu.
        status.onLeftClick = { [weak self] in self?.handleLeftClick() }
        status.onRightClick = { [weak self] button in self?.showMenu(from: button) }

        // A mutation from the panel repaints the menu bar without waiting for the
        // file watcher's debounce, so the switch and the glyph never disagree.
        bridge.onStateChanged = { [weak self] in
            guard let self else { return }
            self.statusItem?.update(with: StateStore.shared.state)
        }

        panel.onWillOpen = {
            // launchd state and the active gh account have no file write to hang
            // an event off, so they are re-read when someone actually looks.
            StateStore.shared.refreshFromCLI()
        }

        menu.onOpenPanel = { [weak self] view in self?.openPanel(view) }

        StateStore.shared.onChange = { [weak self] state in
            self?.statusItem?.update(with: state)
            self?.panelController?.push(state)
        }
        StateStore.shared.start()
        // Adopt the notification queue's current end BEFORE anything can append to
        // it, so launching the app never replays a day's worth of stale banners.
        Notifier.shared.drain()

        if !CLI.shared.isConfigured {
            // Nothing will work, and the reason is an install problem rather than
            // anything the user did. Say so once, at launch, not on first click.
            log.error("GBLCLIPath is missing or not executable; every action will fail")
            warnAboutMissingCLI()
        }

        panel.prewarm()
    }

    func applicationWillTerminate(_ notification: Notification) {
        StateStore.shared.stop()
    }

    /// No windows, so there is nothing for this to be true about; being explicit
    /// stops a future stray window from taking the app down with it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the app in the Dock or Finder while it is already running should
    /// show the panel rather than do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openPanel(.settings)
        return true
    }

    // MARK: - Single instance

    private func terminateIfAlreadyRunning() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0 != NSRunningApplication.current }
        guard let other = others.first else { return false }

        log.notice("another copy is already running; handing over and quitting")
        // Activate the incumbent so the click that started us is not just ignored.
        other.activate(options: [])
        NSApp.terminate(nil)
        return true
    }

    // MARK: - Clicks

    private func handleLeftClick() {
        guard let button = statusItem?.button else { return }

        // An unfinished setup opens the wizard, not settings. Someone who has not
        // told the Goblin which account to review as cannot make any sense of a
        // settings panel, and the wizard is the only screen that can fix it.
        if !StateStore.shared.state.setupComplete {
            openPanel(.wizard)
            return
        }
        panelController?.toggle(relativeTo: button)
    }

    private func showMenu(from button: NSStatusBarButton) {
        // The popover would otherwise sit on top of the menu.
        panelController?.close()
        guard let menu = menuController?.menu(for: StateStore.shared.state) else { return }
        // statusItem.menu stays nil; see StatusItemController's header for why.
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 5),
                   in: button)
    }

    private func openPanel(_ view: MenuController.PanelView) {
        guard let button = statusItem?.button, let panel = panelController else { return }
        if !panel.isShown {
            panel.show(relativeTo: button)
        }
        panel.request(view: view)
    }

    // MARK: - Install problems

    private func warnAboutMissingCLI() {
        let alert = NSAlert()
        alert.messageText = "The Merge Goblin's command line tool is missing"
        alert.informativeText = """
            This app talks to the goblin CLI, and the path baked into it at install \
            time is not there any more.

            Re-run the installer, or rebuild the app with:

                goblin app rebuild
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
