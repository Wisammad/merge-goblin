//  Bridge.swift — the one door from JavaScript into native code.
//
//  Wire protocol, matching share/ui/panel.js's `call()`:
//
//    request   window.webkit.messageHandlers.goblin.postMessage(
//                { v: 1, cmd: "<verb>", args: { ... } })       args is an OBJECT
//
//    reply     { ok: true,  data: <parsed json | string | null>, state: <push> }
//              { ok: false, error: { code, message, exit } }
//
//    codes     refused   the allowlist said no; nothing ran
//              timeout   the CLI was killed by the watchdog
//              notFound  the CLI is not where the bundle says it is
//              cliError  the CLI ran and exited non-zero
//              busy      a duplicate request was already in flight
//
//  A refusal RESOLVES with ok:false rather than rejecting. panel.js treats a
//  rejected promise as "lost contact with the Goblin" and shows an alarming
//  banner, which is wrong for "you cannot do that".
//
//  Refusals are logged with os_log, verb name only. The payload is never logged:
//  it is the one place a hostile string is known to be present, and a log line is
//  read later by a human with a terminal.

import AppKit
import WebKit
import os

@MainActor
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {

    static let handlerName = "goblin"

    /// Set by AppDelegate. Called after any mutation so the menu bar and the
    /// panel agree without waiting for the file watcher's debounce.
    var onStateChanged: (() -> Void)?

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "goblin", category: "bridge")
    /// Collapses a user hammering a toggle into one CLI run per verb.
    private var inFlight: Set<String> = []

    // MARK: - WKScriptMessageHandlerWithReply

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        handle(body: message.body, replyHandler: replyHandler)
    }

    private func handle(body: Any, replyHandler: @escaping (Any?, String?) -> Void) {
        let command: Command
        let plan: Plan
        do {
            command = try Command.parse(body: body)
            plan = try command.validatedPlan()
        } catch let refusal as CommandRefusal {
            // Verb only. Never the args.
            let verb = (body as? [String: Any])?["cmd"] as? String
            log.error("refused \(verb ?? "<no verb>", privacy: .public): \(refusal.reason, privacy: .public)")
            replyHandler(Bridge.failure(code: "refused", message: refusal.reason), nil)
            return
        } catch {
            log.error("refused a message that could not be parsed")
            replyHandler(Bridge.failure(code: "refused", message: "that request was refused"), nil)
            return
        }

        switch plan {
        case .local(let action):
            perform(action, replyHandler: replyHandler)

        case .cli(let argv, let timeout, let mutating, let json):
            let key = argv.joined(separator: " ")
            guard !inFlight.contains(key) else {
                replyHandler(Bridge.failure(code: "busy", message: "that is already running"), nil)
                return
            }
            inFlight.insert(key)

            CLI.shared.run(argv: argv, timeout: timeout, mutating: mutating) { [weak self] result in
                guard let self else { return }
                self.inFlight.remove(key)
                switch result {
                case .success(let output):
                    if mutating {
                        // The bash mutations all end in status_set, which rewrites
                        // uistate.json before exiting, so the files are already
                        // current — this is a re-read, not a second subprocess.
                        StateStore.shared.reloadNow()
                        self.onStateChanged?()
                    }
                    let data: Any = json
                        ? (JSON.parse(output.stdout).raw ?? NSNull())
                        : output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    replyHandler(Bridge.success(data: data), nil)

                case .failure(let failure):
                    replyHandler(Bridge.failure(failure), nil)
                }
            }
        }
    }

    // MARK: - Local actions

    private func perform(_ action: LocalAction, replyHandler: @escaping (Any?, String?) -> Void) {
        switch LocalActions.run(action) {
        case .success(let value):
            replyHandler(Bridge.success(data: value), nil)
        case .failure(let problem):
            replyHandler(Bridge.failure(code: problem.code, message: problem.message), nil)
        }
    }

    // MARK: - Replies
    //
    // Dictionaries, not JSON strings: WebKit serialises NSDictionary/NSArray/
    // NSString/NSNumber/NSNull into real JS values, so the panel never parses.

    private static func success(data: Any) -> [String: Any] {
        [
            "ok": true,
            "data": data,
            "state": StateStore.shared.state.pushPayload(),
        ]
    }

    private static func failure(code: String, message: String, exit: Int32? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let exit { error["exit"] = Int(exit) }
        return ["ok": false, "error": error]
    }

    private static func failure(_ failure: CLI.Failure) -> [String: Any] {
        switch failure {
        case .notFound(let message):
            return Bridge.failure(code: "notFound", message: message)
        case .timeout:
            return Bridge.failure(code: "timeout", message: "the Goblin took too long and was stopped")
        case .cliError(let message, let exit):
            return Bridge.failure(code: "cliError", message: message, exit: exit)
        }
    }
}

// MARK: - Local actions

/// The things Swift does itself rather than shelling out for. Shared by the
/// bridge and the menu, so "Open log" means the same thing in both.
///
/// `openLog`/`openConfig` compute their own path, so there is nothing for a
/// caller to influence. `openURL` was already validated to be https by
/// Command.swift and is handed to NSWorkspace, which resolves it as a URL —
/// unlike `open(1)`, which resolves its argument as a path first and can be
/// talked into launching things.
enum LocalActions {

    struct Problem: Error {
        let code: String
        let message: String
    }

    @discardableResult
    static func run(_ action: LocalAction) -> Result<Any, Problem> {
        switch action {
        case .openLog:
            return reveal(path: CLI.shared.logPath)
        case .openConfig:
            return reveal(path: CLI.shared.configPath)
        case .openURL(let string):
            guard let url = URL(string: string), url.scheme?.lowercased() == "https" else {
                return .failure(Problem(code: "refused", message: "that link cannot be opened"))
            }
            NSWorkspace.shared.open(url)
            return .success(string)
        case .copyDiagnostics:
            let text = Diagnostics.text(for: StateStore.shared.state)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .success("copied \(text.count) characters")
        }
    }

    private static func reveal(path: String) -> Result<Any, Problem> {
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(Problem(code: "notFound", message: "\(path) does not exist yet"))
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        return .success(path)
    }
}

// MARK: - Diagnostics

/// The "Copy diagnostics" payload. Built from state already in memory: no
/// subprocess, and nothing here that is not already visible in the panel.
enum Diagnostics {
    static func text(for state: GoblinState) -> String {
        var lines: [String] = []
        lines.append("\(state.name) \(state.version)")
        lines.append("app        \(Bundle.main.bundleIdentifier ?? "?") "
                     + "(\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))")
        lines.append("macos      \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("home       \(CLI.shared.home)")
        lines.append("cli        \(CLI.shared.executable?.path ?? "MISSING from Info.plist")")
        lines.append("state      \(state.stateName)"
                     + (state.pausedReason.isEmpty ? "" : " (\(state.pausedReason))"))
        lines.append("glyph      \(state.glyph.rawValue)  count \(state.barCount)")
        lines.append("agent      running=\(state.agentRunning) disabled=\(state.agentDisabled)")
        lines.append("login item \(state.loginItemEnabled)")
        lines.append("provider   \(state.providerId)"
                     + (state.providerModel.isEmpty ? "" : " / \(state.providerModel)"))
        lines.append("github     \(state.login)"
                     + (state.identityOK ? "" : "  MISMATCH, active is \(state.ghActive)"))
        lines.append("inbox      waiting=\(state.waiting) mine=\(state.mine) stale=\(state.inboxStale)")
        lines.append("today      \(state.reviewsToday) reviews")
        lines.append("doctor     \(state.doctorFail) failures, \(state.doctorWarn) warnings")
        lines.append("setup      complete=\(state.setupComplete)")
        return lines.joined(separator: "\n") + "\n"
    }
}
