//  MenuController.swift — the right-click menu.
//
//  Emoji ARE fine in here. An NSMenuItem title is ordinary attributed text drawn
//  in colour; it is only the status-bar IMAGE that has to be a monochrome
//  template mask, which is why BarIcon.swift draws paths instead.
//
//  Two labels are deliberately long, and must stay that way:
//
//      "Turn off — stops all reviewing"
//      "Quit — reviews keep running"
//
//  The review engine is a SEPARATE launchd job. This app is a window onto it.
//  So the two highest-risk confusions are quitting the app expecting reviews to
//  stop, and turning the goblin off expecting only the window to close. Neither
//  is recoverable by exploring the UI — you find out days later, from the absence
//  of reviews or from a surprise bill. Both are free to prevent, in the label.

import AppKit

final class MenuController: NSObject {

    /// Ask the app to open the panel. `view` is a hint the panel may ignore.
    var onOpenPanel: ((PanelView) -> Void)?

    enum PanelView: String {
        case settings
        case wizard
        case health
    }

    /// How many PRs go in the submenu before it turns into "…and N more". Eight
    /// is about where a menu stops being scannable.
    private static let maxListedPullRequests = 8

    private var providerProbe: ProviderProbe = ProviderProbe()

    // MARK: - Building

    func menu(for state: GoblinState) -> NSMenu {
        // Refreshing here rather than on a timer: the probe spawns up to three
        // CLIs, and nobody needs that when the menu is closed.
        providerProbe.refreshIfStale()

        let menu = NSMenu()
        menu.autoenablesItems = false

        header(menu, state)
        problems(menu, state)
        inbox(menu, state)
        reviewing(menu, state)
        power(menu, state)
        provider(menu, state)
        stats(menu, state)
        housekeeping(menu, state)
        footer(menu, state)

        return menu
    }

    // MARK: - Sections

    private func header(_ menu: NSMenu, _ state: GoblinState) {
        // bar.tooltip is a fragment ("idle — 3 waiting"), so the name goes in front
        // of it here rather than being baked into bash's string.
        menu.addItem(disabled("👺 \(state.name) — \(state.statusLine)"))
        if state.glyph == .reviewing, !state.activity.isEmpty {
            let item = disabled("   \(truncate(state.activity, 60))")
            item.attributedTitle = dimmed("   \(truncate(state.activity, 60))")
            menu.addItem(item)
        }
    }

    /// The rows that mean "something is wrong and here is the one click that
    /// fixes it". Each is conditional, so a healthy goblin shows none of them.
    private func problems(_ menu: NSMenu, _ state: GoblinState) {
        var added = false

        if !state.setupComplete {
            menu.addItem(.separator()); added = true
            menu.addItem(action("⚠️ Finish setting up the Goblin…") { [weak self] in
                self?.onOpenPanel?(.wizard)
            })
        }

        if state.doctorFail > 0 {
            if !added { menu.addItem(.separator()); added = true }
            let what = state.doctorFail == 1 ? "1 check is failing" : "\(state.doctorFail) checks are failing"
            menu.addItem(action("⚠️ \(what) — open Health…") { [weak self] in
                self?.onOpenPanel?(.health)
                self?.run(.doctor(fix: false))
            })
        }

        if !state.identityOK {
            if !added { menu.addItem(.separator()); added = true }
            let active = state.ghActive.isEmpty ? "another account" : "@\(state.ghActive)"
            let item = action("⚠️ GitHub is signed in as \(active) — switch back") { [weak self] in
                self?.run(.fixAccount)
            }
            item.toolTip = "The Goblin reviews as @\(state.login). "
                + "While another account is active it will find nothing to review."
            menu.addItem(item)
        }

        if !state.agentDisabled, state.enabled, !state.agentRunning {
            if !added { menu.addItem(.separator()) }
            let item = action("⚠️ Review agent is not loaded — start it") { [weak self] in
                self?.run(.agent(.start))
            }
            item.toolTip = "The Goblin is switched on but launchd is not running it, "
                + "so nothing is on a schedule."
            menu.addItem(item)
        }
    }

    private func inbox(_ menu: NSMenu, _ state: GoblinState) {
        menu.addItem(.separator())

        var summary = "\(state.waiting) waiting on the team · \(state.mine) yours"
        if state.inboxStale { summary += "  (out of date)" }
        menu.addItem(disabled(summary))

        let prs = state.pullRequests
        guard !prs.isEmpty else { return }

        let parent = NSMenuItem(title: "Pull requests", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for pr in prs.prefix(MenuController.maxListedPullRequests) {
            let item = action(truncate(pr.label, 70)) { [weak self] in
                self?.run(.openURL(pr.url))
            }
            item.toolTip = pr.url
            submenu.addItem(item)
        }
        let hidden = prs.count - MenuController.maxListedPullRequests
        if hidden > 0 {
            submenu.addItem(disabled("…and \(hidden) more"))
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func reviewing(_ menu: NSMenu, _ state: GoblinState) {
        menu.addItem(.separator())

        let now = action("Review now", key: "r") { [weak self] in self?.run(.reviewNow) }
        now.isEnabled = state.glyph != .reviewing
        now.toolTip = state.glyph == .reviewing ? "A review is already running." : nil
        menu.addItem(now)

        menu.addItem(action("Dry run (posts nothing)") { [weak self] in self?.run(.dryRun) })
    }

    private func power(_ menu: NSMenu, _ state: GoblinState) {
        menu.addItem(.separator())

        let isOff = state.agentDisabled || !state.enabled
        let isPaused = state.stateName == "paused"

        if !isOff {
            if isPaused {
                menu.addItem(action("Resume") { [weak self] in self?.run(.resume) })
            } else {
                let pause = action("Pause") { [weak self] in self?.run(.pause) }
                pause.toolTip = "Temporary — the Goblin comes back at your next login."
                menu.addItem(pause)
            }

            let snooze = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.addItem(action("1 hour") { [weak self] in self?.run(.snooze(kind: .hour)) })
            submenu.addItem(action("Until tomorrow") { [weak self] in self?.run(.snooze(kind: .tomorrow)) })
            if state.isSnoozed || state.glyph == .snoozed {
                submenu.addItem(.separator())
                submenu.addItem(action("Clear snooze") { [weak self] in self?.run(.snooze(kind: .clear)) })
            }
            snooze.submenu = submenu
            menu.addItem(snooze)
        }

        if isOff {
            let on = action("Turn on") { [weak self] in self?.run(.power(on: true)) }
            on.toolTip = "Puts the Goblin back on duty, and keeps him there across restarts."
            menu.addItem(on)
        } else {
            // Verbatim. See the file header.
            let off = action("Turn off — stops all reviewing") { [weak self] in
                self?.run(.power(on: false))
            }
            off.toolTip = "Switches the review engine off for good, not just this session."
            menu.addItem(off)
        }
    }

    private func provider(_ menu: NSMenu, _ state: GoblinState) {
        menu.addItem(.separator())

        let parent = NSMenuItem(title: "Reviewing with", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for id in ProviderId.allCases {
            let probe = providerProbe.result(for: id.rawValue)
            let item = action(id.rawValue) { [weak self] in self?.run(.setProvider(id)) }
            // AppKit has no radio style for menu items; a checkmark on the current
            // one is what every other Mac app does for a single-choice group.
            item.state = state.providerId == id.rawValue ? .on : .off
            if let probe, !probe.ready {
                item.isEnabled = false
                item.toolTip = probe.reason
            }
            submenu.addItem(item)
        }
        if !state.providerModel.isEmpty {
            submenu.addItem(.separator())
            submenu.addItem(disabled("model: \(truncate(state.providerModel, 40))"))
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func stats(_ menu: NSMenu, _ state: GoblinState) {
        menu.addItem(.separator())
        let count = state.reviewsToday == 1 ? "1 review" : "\(state.reviewsToday) reviews"
        let spend = String(format: "$%.2f", state.spendToday)
        menu.addItem(disabled("Today: \(count) · \(spend)"))
    }

    private func housekeeping(_ menu: NSMenu, _ state: GoblinState) {
        menu.addItem(.separator())

        menu.addItem(action("Settings…", key: ",") { [weak self] in self?.onOpenPanel?(.settings) })
        menu.addItem(action("Set-up wizard…") { [weak self] in self?.onOpenPanel?(.wizard) })
        menu.addItem(action("Health check…") { [weak self] in
            self?.onOpenPanel?(.health)
            self?.run(.doctor(fix: false))
        })
        menu.addItem(action("Open log") { LocalActions.run(.openLog) })
        menu.addItem(action("Copy diagnostics") { LocalActions.run(.copyDiagnostics) })

        menu.addItem(.separator())
        let login = action("Start at login") { [weak self] in
            self?.run(.loginItem(on: !state.loginItemEnabled))
        }
        login.state = state.loginItemEnabled ? .on : .off
        login.toolTip = "Opens this menu bar item at login. "
            + "Reviewing is scheduled separately and does not need it."
        menu.addItem(login)
    }

    private func footer(_ menu: NSMenu, _ state: GoblinState) {
        menu.addItem(.separator())
        let version = state.version.isEmpty ? "" : " \(state.version)"
        menu.addItem(disabled("\(state.name)\(version)"))
        // Verbatim. See the file header.
        let quit = action("Quit — reviews keep running", key: "q") {
            NSApp.terminate(nil)
        }
        quit.toolTip = "Closes this menu bar item only. "
            + "The review agent is a separate background job and stays on."
        menu.addItem(quit)
    }

    // MARK: - Running commands

    /// Fire and forget, with a visible failure. The panel has its own error
    /// surface; a menu has none, so a failed action gets an alert rather than
    /// disappearing silently.
    private func run(_ command: Command) {
        let plan: Plan
        do {
            plan = try command.validatedPlan()
        } catch {
            present(title: "The Goblin refused that", message: String(describing: error))
            return
        }

        switch plan {
        case .local(let action):
            if case .failure(let problem) = LocalActions.run(action) {
                present(title: "Could not do that", message: problem.message)
            }
        case .cli(let argv, let timeout, let mutating, _):
            CLI.shared.run(argv: argv, timeout: timeout, mutating: mutating) { result in
                switch result {
                case .success:
                    if mutating { StateStore.shared.reloadNow() }
                case .failure(let failure):
                    switch failure {
                    case .notFound(let message):
                        self.present(title: "The Goblin's CLI is missing", message: message)
                    case .timeout:
                        self.present(title: "That took too long",
                                     message: "The Goblin was stopped after \(Int(timeout.seconds)) seconds.")
                    case .cliError(let message, let code):
                        self.present(title: "That did not work", message: "\(message)\n\nexit \(code)")
                    }
                }
            }
        }
    }

    private func present(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(message.prefix(1000))
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        // An accessory app has no windows, so this has to be app-modal.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Item helpers

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, key: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, handler: handler)
        item.isEnabled = true
        return item
    }

    private func dimmed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    private func truncate(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

// MARK: - A menu item that carries its own closure

/// Saves a selector-per-action and a parallel tag enum. The item retains the
/// closure and is retained by the menu, which is rebuilt on every open, so
/// nothing outlives the menu it belongs to.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used: this app has no nib") }

    @objc private func fire() { handler() }
}

// MARK: - Provider readiness

/// Caches `goblin provider list --json` so the menu can grey out a provider that
/// is not installed or not signed in, and say why in the tooltip.
///
/// Probing spawns one process per provider, so it is cached for a minute and only
/// ever refreshed while the menu is being built. If the verb does not exist yet,
/// or fails, the cache stays empty and every provider is offered — degrading to
/// "let bash refuse it" rather than to "nothing is selectable".
private final class ProviderProbe {

    struct Result {
        let ready: Bool
        let reason: String?
    }

    private var results: [String: Result] = [:]
    private var lastRefresh: Date = .distantPast
    private var inFlight = false

    func result(for id: String) -> Result? { results[id] }

    func refreshIfStale(maxAge: TimeInterval = 60) {
        guard !inFlight, Date().timeIntervalSince(lastRefresh) > maxAge else { return }
        guard case .cli(let argv, let timeout, let mutating, _) =
                (try? Command.providers(refresh: false).validatedPlan()) else { return }
        inFlight = true
        CLI.shared.run(argv: argv, timeout: timeout, mutating: mutating) { [weak self] outcome in
            guard let self else { return }
            self.inFlight = false
            self.lastRefresh = Date()
            guard case .success(let output) = outcome else { return }
            var parsed: [String: Result] = [:]
            for entry in JSON.parse(output.stdout).array {
                let id = entry["id"].string ?? entry["name"].string ?? ""
                guard !id.isEmpty else { continue }
                let ready = entry["state"].string == "ready"
                    || (entry["available"].bool(false) && entry["authed"].bool(false))
                let note = entry["note"].string ?? entry["detail"].string ?? ""
                parsed[id] = Result(ready: ready, reason: note.isEmpty ? nil : note)
            }
            self.results = parsed
        }
    }
}
