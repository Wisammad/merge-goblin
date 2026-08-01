//  StateStore.swift — what the goblin currently knows, and how it finds out.
//
//  Two sources:
//
//    1. ~/.goblin/uistate.json and ~/.goblin/inbox.json, watched for changes.
//       The watch is on the DIRECTORY, not the files. Every writer in lib/ ends
//       with `mv "$X.tmp" "$X"`, so the inode we would have been watching is
//       orphaned by the first write and we would get exactly one event, ever.
//       Watching the directory for .write survives replacement.
//
//    2. `goblin status --json` every five minutes, and on popover open. Some
//       facts have no file write to hang an event off: whether launchd still has
//       the review agent loaded, and which gh account is active. Those only
//       become true again when something asks.
//
//  Parsing is deliberately by hand rather than Codable. Another agent is adding
//  bar/inbox/setup to ui_state_write right now, and a JSON document that is one
//  key short — or has a number where we expected a string — must degrade to a
//  sensible default, not fail the whole decode and blank the menu bar.

import Foundation
import os

// MARK: - A forgiving JSON reader

/// Tree walker that never throws and never traps. Every accessor returns nil (or
/// an empty collection) for "absent, or not the type I wanted".
struct JSON {
    let raw: Any?

    init(_ raw: Any?) {
        if let raw, raw is NSNull { self.raw = nil } else { self.raw = raw }
    }

    static func parse(_ data: Data) -> JSON {
        JSON(try? JSONSerialization.jsonObject(with: data, options: []))
    }

    static func parse(_ text: String) -> JSON {
        guard let data = text.data(using: .utf8) else { return JSON(nil) }
        return parse(data)
    }

    static func read(path: String) -> JSON {
        guard let data = FileManager.default.contents(atPath: path) else { return JSON(nil) }
        return parse(data)
    }

    subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSON {
        guard let array = raw as? [Any], index >= 0, index < array.count else { return JSON(nil) }
        return JSON(array[index])
    }

    var exists: Bool { raw != nil }
    var string: String? { raw as? String }
    var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }
    var object: [String: Any]? { raw as? [String: Any] }

    var int: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    var bool: Bool? {
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String { return s == "true" || s == "yes" || s == "1" }
        return nil
    }

    func string(_ fallback: String) -> String { string ?? fallback }
    func int(_ fallback: Int) -> Int { int ?? fallback }
    func bool(_ fallback: Bool) -> Bool { bool ?? fallback }
    func double(_ fallback: Double) -> Double { double ?? fallback }
}

// MARK: - Derived view of the state

struct PullRequest {
    let repo: String
    let number: Int
    let title: String
    let url: String

    /// "owner/name #123" — what the submenu shows.
    var label: String {
        let shortRepo = repo.split(separator: "/").last.map(String.init) ?? repo
        let head = number > 0 ? "\(shortRepo) #\(number)" : shortRepo
        return title.isEmpty ? head : "\(head)  \(title)"
    }
}

struct GoblinState {
    var ui: JSON = JSON(nil)
    var inbox: JSON = JSON(nil)
    var config: JSON = JSON(nil)
    /// Newest first, capped. Straight out of events.jsonl.
    var history: [[String: Any]] = []
    /// Whether the login-item LaunchAgent plist exists. Read from disk rather
    /// than asked of bash, so the menu can draw its checkmark synchronously.
    var loginItemEnabled: Bool = false

    // --- identity of the product ------------------------------------------
    var name: String { ui["goblin"]["name"].string("The Merge Goblin") }
    var shortName: String { "Merge Goblin" }
    var version: String { ui["goblin"]["version"].string("") }

    // --- lifecycle --------------------------------------------------------
    var stateName: String { ui["state"].string("idle") }
    var pausedReason: String { ui["pausedReason"].string("") }
    var activity: String { ui["activity"].string("") }
    var enabled: Bool { ui["enabled"].bool(true) }
    var agentRunning: Bool { ui["agent"]["running"].bool(false) }
    var agentDisabled: Bool { ui["agent"]["disabled"].bool(false) }
    var snoozeUntil: Double { ui["snoozeUntil"].double(0) }
    var isSnoozed: Bool { snoozeUntil > Date().timeIntervalSince1970 }

    /// setup.complete is being added by another agent. Absent means "assume the
    /// install is fine" — showing a first-run wizard to someone who has been
    /// using this for a month would be much worse than not showing it at all.
    var setupComplete: Bool { ui["setup"]["complete"].bool(true) }

    // --- the bar ----------------------------------------------------------
    /// The glyph name comes FROM BASH. Swift is a name -> NSImage lookup and
    /// nothing more, so changing when the goblin looks worried is a one-line
    /// change in lib/, not a rebuild. The fallback below only runs against a
    /// state file written by a version that does not set bar.glyph yet.
    var glyph: BarGlyph {
        // The one policy Swift keeps for itself: an unfinished set-up always looks
        // like a problem, whatever bash said. Every other state is cosmetic, but
        // "the goblin has never been configured and is therefore doing nothing"
        // must not be able to render as a calm idle face — that is the state a
        // user would leave alone for a week.
        if !setupComplete { return .error }
        if let named = ui["bar"]["glyph"].string, let g = BarGlyph(rawValue: named) { return g }
        if agentDisabled || !enabled { return .off }
        switch stateName {
        case "reviewing": return .reviewing
        case "snoozed":   return .snoozed
        case "paused":    return (pausedReason == "quota" || pausedReason == "budget") ? .quota : .paused
        case "disabled":  return .off
        default:          return isSnoozed ? .snoozed : .idle
        }
    }

    var barCount: Int {
        // An incomplete setup shows the error glyph with no number: a count is a
        // to-do list, and there is nothing to do until the wizard has run.
        guard setupComplete else { return 0 }
        if let n = ui["bar"]["count"].int { return max(0, n) }
        return max(0, waiting)
    }

    /// The short fragment bash writes to bar.tooltip: "idle — 3 waiting",
    /// "wrong GitHub account", "not set up yet". Deliberately not a sentence,
    /// so it can be composed into both the hover tooltip and the menu header.
    var statusLine: String {
        if let t = ui["bar"]["tooltip"].string, !t.isEmpty { return t }
        var text = stateName
        if !pausedReason.isEmpty { text += " (\(pausedReason))" }
        return text
    }

    var tooltip: String { "\(name) — \(statusLine)" }

    // --- inbox ------------------------------------------------------------
    var waiting: Int {
        ui["inbox"]["waiting"].int ?? inbox["counts"]["waiting"].int(0)
    }
    var mine: Int {
        ui["inbox"]["mine"].int ?? inbox["counts"]["mine"].int(0)
    }
    var inboxStale: Bool { ui["inbox"]["stale"].bool(false) }

    /// Only the ones actually waiting. inbox.json carries every PR it looked at —
    /// reviewed, blocked, drafts, assigned to a teammate — and a menu that lists
    /// all of them under a count of three is worse than no list at all. An entry
    /// with no `state` at all is kept, so an older inbox.json still shows
    /// something rather than nothing.
    var pullRequests: [PullRequest] {
        inbox["prs"].array.compactMap { entry in
            let url = entry["url"].string("")
            guard !url.isEmpty else { return nil }
            if let state = entry["state"].string, state != "waiting" { return nil }
            return PullRequest(repo: entry["repo"].string(""),
                               number: entry["number"].int(0),
                               title: entry["title"].string(""),
                               url: url)
        }
    }

    // --- provider / identity / spend --------------------------------------
    var providerId: String { ui["provider"]["id"].string("claude") }
    var providerModel: String { ui["provider"]["model"].string("") }
    var login: String { ui["identity"]["login"].string("") }
    var ghActive: String { ui["identity"]["ghActive"].string("") }
    var identityOK: Bool { ui["identity"]["ok"].bool(true) }
    var reviewsToday: Int { ui["reviews"]["today"].int(0) }
    var spendToday: Double { ui["spendUsd"]["today"].double(0) }
    var doctorFail: Int { ui["doctor"]["fail"].int(0) }
    var doctorWarn: Int { ui["doctor"]["warn"].int(0) }

    /// The blob pushed into the web view, and echoed back as `state` on every
    /// bridge reply. The key names are exactly what share/ui/panel.js's
    /// normalizeState() reads; the contract is written out at the bottom of
    /// Bridge.swift.
    ///
    ///   { v, status, config, inbox, history, home, loginItem, app }
    ///
    /// config and history are included because the panel needs them and there is
    /// no reason to spend a subprocess on a file this app can read itself.
    func pushPayload() -> [String: Any] {
        var payload: [String: Any] = ["v": 1]
        payload["status"] = ui.object ?? [:]
        payload["config"] = config.object ?? [:]
        payload["inbox"] = inbox.object ?? [:]
        payload["history"] = history
        payload["home"] = CLI.shared.home
        payload["loginItem"] = loginItemEnabled
        payload["app"] = [
            "version": version,
            "cliConfigured": CLI.shared.isConfigured,
            "setupComplete": setupComplete,
        ]
        return payload
    }
}

// MARK: - The store

final class StateStore {

    static let shared = StateStore()

    private(set) var state = GoblinState()

    /// Called on the main queue whenever anything changed.
    var onChange: ((GoblinState) -> Void)?

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "goblin", category: "state")
    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    private var debounce: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var refreshInFlight = false

    private init() {}

    // MARK: lifecycle

    func start() {
        reloadFromDisk(notify: true)
        startWatching()
        // Five minutes: long enough to be free, short enough that a menu opened
        // an hour after the agent was booted out is not lying.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshFromCLI()
        }
        refreshTimer?.tolerance = 30
        refreshFromCLI()
    }

    func stop() {
        source?.cancel()
        source = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: reading

    /// Re-reads everything from disk. Cheap: three small JSON files and the tail
    /// of one log, no subprocess.
    func reloadFromDisk(notify: Bool) {
        var next = GoblinState()
        next.ui = JSON.read(path: CLI.shared.uiStatePath)
        next.inbox = JSON.read(path: CLI.shared.inboxPath)
        next.config = JSON.read(path: CLI.shared.configPath)
        next.history = StateStore.readHistory(path: CLI.shared.eventsPath)
        next.loginItemEnabled = LoginItem.isInstalled
        state = next
        if notify { onChange?(state) }
    }

    /// The last few rows of events.jsonl, newest first.
    ///
    /// The whole file is read and then discarded: it is one line per review and
    /// lib/core.sh rotates the log, not this, so in practice it is single-digit
    /// kilobytes. If that ever stops being true, this is the place to seek from
    /// the end instead.
    private static func readHistory(path: String, limit: Int = 25) -> [[String: Any]] {
        guard let data = FileManager.default.contents(atPath: path),
              data.count < 4 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else { return [] }
        var rows: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit) {
            if let row = JSON.parse(String(line)).object { rows.append(row) }
        }
        return rows.reversed()
    }

    /// Replaces the ui half from a `status --json` stdout, which IS uistate.json.
    private func adopt(uiStateJSON text: String) {
        let parsed = JSON.parse(text)
        guard parsed.exists else { return }
        state.ui = parsed
        state.loginItemEnabled = LoginItem.isInstalled
        onChange?(state)
    }

    /// The facts no file write can signal. Safe to call on every popover open —
    /// it collapses concurrent calls into one.
    func refreshFromCLI() {
        guard CLI.shared.isConfigured, !refreshInFlight else { return }
        refreshInFlight = true
        CLI.shared.run(argv: ["status", "--json"], timeout: .read, mutating: false) { [weak self] result in
            guard let self else { return }
            self.refreshInFlight = false
            switch result {
            case .success(let out):
                self.adopt(uiStateJSON: out.stdout)
            case .failure(let error):
                self.log.error("state refresh failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: watching

    private func startWatching() {
        let home = CLI.shared.home
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory), isDirectory.boolValue else {
            // Not installed yet. The five-minute refresh will keep trying, and
            // reattaching is cheap, so there is nothing to schedule here.
            log.notice("state directory does not exist yet; watching deferred")
            return
        }

        let fd = open(home, O_EVTONLY)
        guard fd >= 0 else {
            log.error("cannot open \(home, privacy: .public) for watching")
            return
        }
        directoryFD = fd

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main)

        newSource.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        newSource.setCancelHandler { [weak self] in
            if let self, self.directoryFD >= 0 {
                close(self.directoryFD)
                self.directoryFD = -1
            }
        }
        newSource.resume()
        source = newSource
    }

    /// 150ms of debounce. A single `status_set` rewrites status.json and then
    /// uistate.json, so one logical change is two or three directory events; the
    /// menu bar must not flicker through the intermediate states.
    private func scheduleReload() {
        // The engine's notification queue lives in the same directory, so the event
        // that says state changed also says a banner may be waiting. Drained OUTSIDE
        // the debounce on purpose: notifications are not a state read, and
        // coalescing them would drop banners whenever several writes land together.
        Notifier.shared.drain()

        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadFromDisk(notify: true)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Called after a mutation completes, so the reply carries fresh state. The
    /// bash mutations all end in status_set, which rewrites uistate.json before
    /// exiting, so by the time we are here the file is already current.
    func reloadNow() {
        debounce?.cancel()
        reloadFromDisk(notify: true)
    }
}

// MARK: - Login item

/// The login item is a LaunchAgent (see templates/bar-agent.plist.tmpl for why it
/// is not SMAppService). Swift only ever reads its existence; writing it goes
/// through `goblin app login-item on|off` so there is one implementation.
enum LoginItem {
    static var label: String {
        // Mirrors goblin_agent_label() in lib/paths.sh, plus ".bar".
        let user = NSUserName().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-" }
            .map(String.init)
            .joined()
        return "com.\(user.isEmpty ? "user" : user).goblin.bar"
    }

    static var plistPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }
}
