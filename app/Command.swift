//  Command.swift — the allowlist.
//
//  Everything the panel is allowed to ask for lives in this one file, as a closed
//  enum plus a static table that builds the argv. Nothing else in the app may
//  construct a CLI argument list.
//
//  It imports Foundation and NOTHING ELSE — no AppKit, no WebKit — so app-tests
//  can compile and exercise it headlessly, with no window server and no bundle.
//  If you ever need AppKit here, you have put the wrong thing in this file.
//
//  Why this is stricter than the python server it replaces:
//
//      share/ui/server.py's ALLOWED table was  verb -> max-arg-count, e.g.
//      "config": 3. That permits  `goblin config set <any jq path> <any value>`,
//      which is the whole config plane — including `.providers.claude.bin`,
//      i.e. "run this binary as me, on a timer, forever". A verb+arity check can
//      never close that; only naming the individual settings can. So there is
//      deliberately NO case here that takes a config path, and NO case that can
//      set a provider binary path.
//
//  Hard rules, all failing closed:
//    * the message body must be a dictionary
//    * "v" must be exactly 1
//    * the re-serialised body must be <= 8 KiB
//    * "args" must be an object (never an array) and unknown keys are a REFUSAL,
//      not something we quietly ignore — a typo'd key is far more likely to be a
//      probe than a mistake, and silently dropping it hides both
//    * no element of a built argv may begin with "-" unless it is one of the
//      literal flags in `Command.allowedFlagLiterals`

import Foundation

// MARK: - Errors

/// The single failure mode of parsing. `reason` is developer-facing English and
/// safe to show in the panel; it never echoes the offending value.
struct CommandRefusal: Error, Equatable, CustomStringConvertible {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var description: String { reason }
}

// MARK: - Closed value types
//
// Every free-form-looking argument is one of these, so "unexpected string" is
// unrepresentable rather than merely unlikely.

enum SnoozeKind: String, CaseIterable {
    case hour, tomorrow, clear
}

enum VerdictMode: String, CaseIterable {
    case comment
    case requestChanges = "request-changes"
    case full
}

enum ProviderId: String, CaseIterable {
    case claude, codex, cursor
}

enum AgentAction: String, CaseIterable {
    case start, stop, reload
}

/// The boolean settings the panel may flip. Closed on purpose: this is the list
/// that stops `setFlag` from becoming `config set <path>` by another name.
enum FlagKey: String, CaseIterable {
    case incrementalReview
    case postCommitStatus
    case fleetAssignment
    case notifyStarted
    case notifyPosted
    case notifyFailed
    case notifyBudget
    case notifySound
    case skipIfHumanReviewed

    /// The name bash sees. Kebab-case because that is the CLI's convention.
    var cliName: String {
        switch self {
        case .incrementalReview: return "incremental-review"
        case .postCommitStatus:  return "post-commit-status"
        case .fleetAssignment:   return "fleet-assignment"
        case .notifyStarted:     return "notify-started"
        case .notifyPosted:      return "notify-posted"
        case .notifyFailed:      return "notify-failed"
        case .notifyBudget:      return "notify-budget"
        case .notifySound:       return "notify-sound"
        case .skipIfHumanReviewed: return "skip-if-human-reviewed"
        }
    }
}

// MARK: - How long a command may take, and who serialises it

enum TimeoutClass {
    case read           // reads a file or a cached blob
    case mutation       // writes config/state
    case doctor         // probes github + providers + clones
    case discovery      // network listing (repo search, account list)

    var seconds: TimeInterval {
        switch self {
        case .read:      return 10
        case .mutation:  return 30
        case .doctor:    return 60
        case .discovery: return 45
        }
    }
}

/// Things Swift does itself rather than shelling out for. Opening a file or a URL
/// through a subprocess would mean `open(1)` with an attacker-influenced
/// argument; `NSWorkspace` with a path we computed cannot be talked into
/// anything, and needs no allowlist of its own.
enum LocalAction: Equatable {
    case openLog
    case openConfig
    case openURL(String)      // already validated to be https://
    case copyDiagnostics
}

/// The result of parsing: either an argv to hand to the CLI, or something local.
enum Plan: Equatable {
    /// - Parameters:
    ///   - argv: the exact arguments, in order. Never passed through a shell.
    ///   - timeout: which watchdog applies.
    ///   - mutating: true => runs on the `mutations` queue and triggers a state
    ///     reload afterwards. false => runs on the `reads` queue.
    ///   - json: stdout is expected to be a single JSON document.
    case cli(argv: [String], timeout: TimeoutClass, mutating: Bool, json: Bool)
    case local(LocalAction)
}

// MARK: - The commands

enum Command: Equatable {
    // power / scheduling
    case power(on: Bool)
    case pause
    case resume
    case snooze(kind: SnoozeKind)

    // reviewing
    case reviewNow
    case dryRun

    // budgets and limits
    case setMaxReviewsPerDay(Int)      // 0...500   (0 = no cap)
    case setMaxReviewsPerRun(Int)      // 1...50
    case setMaxFindings(Int)           // 1...200
    case setIntervalMinutes(Int)       // 1...1440

    // review behaviour
    case setVerdictMode(VerdictMode)
    case setAllowApprove(Bool)
    case setFlag(key: FlagKey, on: Bool)

    // provider
    case setProvider(ProviderId)
    case setProviderModel(provider: ProviderId, model: String)   // ^[A-Za-z0-9._:-]{0,64}$

    // repos
    case repoAdd(slug: String)
    case repoRemove(slug: String)
    case repoEnable(slug: String, on: Bool)

    // identity
    case setIdentity(login: String)    // alnum, (-?[A-Za-z0-9]){0,38}: no leading/trailing hyphen
    case fixAccount

    // diagnostics / plumbing
    case doctor(fix: Bool)
    case agent(AgentAction)

    // reads
    case state
    case inbox(refresh: Bool)
    case accounts
    case providers(refresh: Bool)
    case repoSearch(query: String, limit: Int)   // query ^[A-Za-z0-9 ._/-]{0,80}$, limit 1...200

    // first-run wizard
    case wizardState
    case wizardComplete

    // the app itself
    case loginItem(on: Bool)
    case openLog
    case openConfig
    case openURL(String)
    case copyDiagnostics

    // MARK: verbs

    /// Every verb the bridge answers to. Kept next to `parse` so adding a case
    /// without adding a parse arm is a compile error, not a silent 404.
    static let verbs: [String] = [
        "power", "pause", "resume", "snooze",
        "reviewNow", "dryRun",
        "setMaxReviewsPerDay", "setMaxReviewsPerRun", "setMaxFindings", "setIntervalMinutes",
        "setVerdictMode", "setAllowApprove", "setFlag",
        "setProvider", "setProviderModel",
        "repoAdd", "repoRemove", "repoEnable",
        "setIdentity", "fixAccount",
        "doctor", "agent",
        "state", "inbox", "accounts", "providers", "repoSearch",
        "wizardState", "wizardComplete",
        "loginItem", "openLog", "openConfig", "openURL", "copyDiagnostics",
    ]

    /// The only argv elements allowed to start with "-". Anything else that does
    /// is a refusal, which is what stops a validated-but-hostile value (a repo
    /// slug of "-x/y", a search query of "--help") from turning into a flag.
    static let allowedFlagLiterals: Set<String> = ["--json", "--fix", "--refresh", "--limit", "--query"]

    static let maxBodyBytes = 8 * 1024

    // MARK: - argv

    var plan: Plan {
        switch self {
        case .power(let on):
            return .cli(argv: [on ? "on" : "off"], timeout: .mutation, mutating: true, json: false)
        case .pause:
            return .cli(argv: ["pause"], timeout: .mutation, mutating: true, json: false)
        case .resume:
            return .cli(argv: ["resume"], timeout: .mutation, mutating: true, json: false)
        case .snooze(let kind):
            let verb: String
            switch kind {
            case .hour:     verb = "snooze1h"
            case .tomorrow: verb = "snoozetomorrow"
            case .clear:    verb = "clearsnooze"
            }
            return .cli(argv: [verb], timeout: .mutation, mutating: true, json: false)

        case .reviewNow:
            // run-now detaches in bash. The app must never be the parent of a
            // fifteen-minute review: quitting the app would take the review with it.
            return .cli(argv: ["run-now"], timeout: .mutation, mutating: true, json: false)
        case .dryRun:
            return .cli(argv: ["panel", "dry-run"], timeout: .mutation, mutating: true, json: false)

        case .setMaxReviewsPerDay(let n):
            return Command.panelSet("max-per-day", String(n))
        case .setMaxReviewsPerRun(let n):
            return Command.panelSet("max-per-run", String(n))
        case .setMaxFindings(let n):
            return Command.panelSet("max-findings", String(n))
        case .setIntervalMinutes(let n):
            return Command.panelSet("interval-minutes", String(n))

        case .setVerdictMode(let mode):
            return Command.panelSet("verdict-mode", mode.rawValue)
        case .setAllowApprove(let on):
            return Command.panelSet("allow-approve", on ? "on" : "off")
        case .setFlag(let key, let on):
            return Command.panelSet("flag", key.cliName, on ? "on" : "off")

        case .setProvider(let id):
            return .cli(argv: ["provider", "use", id.rawValue], timeout: .discovery, mutating: true, json: false)
        case .setProviderModel(let provider, let model):
            return Command.panelSet("provider-model", provider.rawValue, model)

        case .repoAdd(let slug):
            return .cli(argv: ["repos", "add", slug], timeout: .mutation, mutating: true, json: false)
        case .repoRemove(let slug):
            return .cli(argv: ["repos", "rm", slug], timeout: .mutation, mutating: true, json: false)
        case .repoEnable(let slug, let on):
            return .cli(argv: ["repos", on ? "enable" : "disable", slug],
                        timeout: .mutation, mutating: true, json: false)

        case .setIdentity(let login):
            return Command.panelSet("identity", login)
        case .fixAccount:
            return .cli(argv: ["fix-account"], timeout: .mutation, mutating: true, json: false)

        case .doctor(let fix):
            return .cli(argv: fix ? ["doctor", "--fix", "--json"] : ["doctor", "--json"],
                        timeout: .doctor, mutating: fix, json: true)
        case .agent(let action):
            return .cli(argv: ["agent", action.rawValue], timeout: .mutation, mutating: true, json: false)

        case .state:
            return .cli(argv: ["status", "--json"], timeout: .read, mutating: false, json: true)
        case .inbox(let refresh):
            return .cli(argv: refresh ? ["inbox", "--refresh", "--json"] : ["inbox", "--json"],
                        timeout: refresh ? .discovery : .read, mutating: false, json: true)
        case .accounts:
            return .cli(argv: ["accounts", "--json"], timeout: .discovery, mutating: false, json: true)
        case .providers(let refresh):
            return .cli(argv: refresh ? ["provider", "list", "--refresh", "--json"]
                                      : ["provider", "list", "--json"],
                        timeout: .discovery, mutating: false, json: true)
        case .repoSearch(let query, let limit):
            return .cli(argv: ["repo-search", "--json", "--limit", String(limit), "--query", query],
                        timeout: .discovery, mutating: false, json: true)

        case .wizardState:
            return .cli(argv: ["wizard", "state", "--json"], timeout: .read, mutating: false, json: true)
        case .wizardComplete:
            return .cli(argv: ["wizard", "complete"], timeout: .mutation, mutating: true, json: false)

        case .loginItem(let on):
            return .cli(argv: ["app", "login-item", on ? "on" : "off"],
                        timeout: .mutation, mutating: true, json: false)

        case .openLog:         return .local(.openLog)
        case .openConfig:      return .local(.openConfig)
        case .openURL(let u):  return .local(.openURL(u))
        case .copyDiagnostics: return .local(.copyDiagnostics)
        }
    }

    /// Every named setting goes through `goblin panel set <name> <value...>`.
    /// One bash entry point, one place to audit, and no jq path in sight.
    private static func panelSet(_ name: String, _ values: String...) -> Plan {
        .cli(argv: ["panel", "set", name] + values, timeout: .mutation, mutating: true, json: false)
    }

    /// The argv after the final safety check. `plan` is the table; this is the
    /// gate. Bridge must call this, never `plan` directly.
    func validatedPlan() throws -> Plan {
        let p = plan
        if case .cli(let argv, _, _, _) = p {
            guard !argv.isEmpty else { throw CommandRefusal("empty argv") }
            for element in argv {
                if element.hasPrefix("-") && !Command.allowedFlagLiterals.contains(element) {
                    throw CommandRefusal("argument would be read as a flag")
                }
                guard !element.contains("\0") else { throw CommandRefusal("argument contains NUL") }
            }
        }
        return p
    }
}

// MARK: - Parsing

extension Command {

    /// Parse a bridge message body. `body` is whatever WebKit deserialised from
    /// JS, so it is NSDictionary/NSString/NSNumber/NSNull/NSArray and nothing else.
    static func parse(body: Any) throws -> Command {
        guard let dict = body as? [String: Any] else {
            throw CommandRefusal("message body must be an object")
        }

        // Size is measured on the re-serialised body rather than trusting a
        // caller-supplied length. 8 KiB is ~40x the biggest legitimate message.
        if JSONSerialization.isValidJSONObject(dict),
           let data = try? JSONSerialization.data(withJSONObject: dict, options: []) {
            guard data.count <= maxBodyBytes else { throw CommandRefusal("message too large") }
        } else {
            throw CommandRefusal("message is not representable as JSON")
        }

        guard let version = Coerce.int(dict["v"]), version == 1 else {
            throw CommandRefusal("unsupported protocol version")
        }
        guard let verb = dict["cmd"] as? String, !verb.isEmpty else {
            throw CommandRefusal("missing cmd")
        }

        // args is an object or absent. An ARRAY is refused: the python server
        // took positional arrays, which is how "one extra element" became "one
        // extra CLI argument".
        var args: [String: Any] = [:]
        if let raw = dict["args"], !(raw is NSNull) {
            guard let obj = raw as? [String: Any] else {
                throw CommandRefusal("args must be an object")
            }
            args = obj
        }

        // Anything other than v/cmd/args at the top level is a refusal too.
        let extras = Set(dict.keys).subtracting(["v", "cmd", "args"])
        guard extras.isEmpty else { throw CommandRefusal("unknown top-level key") }

        var r = ArgReader(args)
        let command: Command

        switch verb {
        case "power":     command = .power(on: try r.bool("on"))
        case "pause":     command = .pause
        case "resume":    command = .resume
        case "snooze":    command = .snooze(kind: try r.enumValue("kind", SnoozeKind.self))

        case "reviewNow": command = .reviewNow
        case "dryRun":    command = .dryRun

        case "setMaxReviewsPerDay": command = .setMaxReviewsPerDay(try r.int("value", 0...500))
        case "setMaxReviewsPerRun": command = .setMaxReviewsPerRun(try r.int("value", 1...50))
        case "setMaxFindings":      command = .setMaxFindings(try r.int("value", 1...200))
        case "setIntervalMinutes":  command = .setIntervalMinutes(try r.int("value", 1...1440))

        case "setVerdictMode":  command = .setVerdictMode(try r.enumValue("value", VerdictMode.self))
        case "setAllowApprove": command = .setAllowApprove(try r.bool("value"))
        case "setFlag":         command = .setFlag(key: try r.enumValue("key", FlagKey.self),
                                                   on: try r.bool("value"))

        case "setProvider": command = .setProvider(try r.enumValue("id", ProviderId.self))
        case "setProviderModel":
            command = .setProviderModel(provider: try r.enumValue("provider", ProviderId.self),
                                        model: try r.pattern("model", .model))

        case "repoAdd":    command = .repoAdd(slug: try r.pattern("slug", .repoSlug))
        case "repoRemove": command = .repoRemove(slug: try r.pattern("slug", .repoSlug))
        case "repoEnable": command = .repoEnable(slug: try r.pattern("slug", .repoSlug),
                                                 on: try r.bool("on"))

        case "setIdentity": command = .setIdentity(login: try r.pattern("login", .githubLogin))
        case "fixAccount":  command = .fixAccount

        case "doctor": command = .doctor(fix: try r.optBool("fix", default: false))
        case "agent":  command = .agent(try r.enumValue("action", AgentAction.self))

        case "state":     command = .state
        case "inbox":     command = .inbox(refresh: try r.optBool("refresh", default: false))
        case "accounts":  command = .accounts
        case "providers": command = .providers(refresh: try r.optBool("refresh", default: false))
        case "repoSearch":
            command = .repoSearch(query: try r.pattern("query", .searchQuery),
                                  limit: try r.optInt("limit", 1...200, default: 30))

        case "wizardState":    command = .wizardState
        case "wizardComplete": command = .wizardComplete

        case "loginItem":       command = .loginItem(on: try r.bool("on"))
        case "openLog":         command = .openLog
        case "openConfig":      command = .openConfig
        case "openURL":         command = .openURL(try r.httpsURL("url"))
        case "copyDiagnostics": command = .copyDiagnostics

        default:
            throw CommandRefusal("unknown command")
        }

        try r.finish()
        return command
    }
}

// MARK: - Argument reading

/// Reads typed values out of the args object and, crucially, remembers which
/// keys it consumed so `finish()` can refuse anything left over.
struct ArgReader {
    private let dict: [String: Any]
    private var used: Set<String> = []

    init(_ dict: [String: Any]) { self.dict = dict }

    mutating func bool(_ key: String) throws -> Bool {
        used.insert(key)
        guard let value = dict[key], let b = Coerce.bool(value) else {
            throw CommandRefusal("\(key) must be a boolean")
        }
        return b
    }

    mutating func optBool(_ key: String, default fallback: Bool) throws -> Bool {
        used.insert(key)
        guard let value = dict[key], !(value is NSNull) else { return fallback }
        guard let b = Coerce.bool(value) else { throw CommandRefusal("\(key) must be a boolean") }
        return b
    }

    mutating func int(_ key: String, _ range: ClosedRange<Int>) throws -> Int {
        used.insert(key)
        guard let value = dict[key], let n = Coerce.int(value) else {
            throw CommandRefusal("\(key) must be a whole number")
        }
        guard range.contains(n) else {
            throw CommandRefusal("\(key) must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return n
    }

    mutating func optInt(_ key: String, _ range: ClosedRange<Int>, default fallback: Int) throws -> Int {
        used.insert(key)
        guard let value = dict[key], !(value is NSNull) else { return fallback }
        guard let n = Coerce.int(value) else { throw CommandRefusal("\(key) must be a whole number") }
        guard range.contains(n) else {
            throw CommandRefusal("\(key) must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return n
    }

    mutating func enumValue<T: RawRepresentable & CaseIterable>(_ key: String, _ type: T.Type) throws -> T
    where T.RawValue == String {
        used.insert(key)
        guard let raw = dict[key] as? String else { throw CommandRefusal("\(key) must be a string") }
        guard let v = T(rawValue: raw) else { throw CommandRefusal("\(key) is not one of the allowed values") }
        return v
    }

    mutating func pattern(_ key: String, _ pattern: Pattern) throws -> String {
        used.insert(key)
        guard let raw = dict[key] as? String else { throw CommandRefusal("\(key) must be a string") }
        guard pattern.accepts(raw) else { throw CommandRefusal("\(key) is not in the accepted format") }
        return raw
    }

    mutating func httpsURL(_ key: String) throws -> String {
        used.insert(key)
        guard let raw = dict[key] as? String else { throw CommandRefusal("\(key) must be a string") }
        guard raw.count <= 2048 else { throw CommandRefusal("\(key) is too long") }
        // Reject before URLComponents so a hostile string never reaches a parser.
        guard raw.hasPrefix("https://") else { throw CommandRefusal("only https links can be opened") }
        guard !raw.contains(where: { $0 == "\0" || $0.isNewline }) else {
            throw CommandRefusal("\(key) contains a control character")
        }
        guard let comps = URLComponents(string: raw), comps.scheme?.lowercased() == "https",
              let host = comps.host, !host.isEmpty, host.count <= 253 else {
            throw CommandRefusal("\(key) is not a usable https url")
        }
        return raw
    }

    /// An unknown key is a refusal, not something to ignore. See the file header.
    func finish() throws {
        let unknown = Set(dict.keys).subtracting(used)
        guard unknown.isEmpty else { throw CommandRefusal("unknown argument") }
    }
}

// MARK: - Coercion

enum Coerce {
    /// Strictly a JSON boolean. `1` is not `true` here: a caller that means
    /// "true" can say so, and accepting both is how "0"/"off"/"no" bugs start.
    static func bool(_ value: Any) -> Bool? {
        if let n = value as? NSNumber {
            return CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() ? n.boolValue : nil
        }
        if let b = value as? Bool { return b }
        return nil
    }

    /// Strictly an integral JSON number. JS has no int type, so 3.0 is fine and
    /// 3.5 is not; NaN/inf are not; a numeric string is not.
    static func int(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let n = value as? NSNumber {
            guard CFGetTypeID(n as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            guard d.isFinite, d.rounded() == d, abs(d) <= 9_007_199_254_740_991 else { return nil }
            return Int(d)
        }
        if let i = value as? Int { return i }
        return nil
    }
}

// MARK: - Patterns
//
// Hand-rolled character scanning rather than NSRegularExpression: the accepted
// sets are tiny, the check is obviously total, and there is no regex engine in
// the path of untrusted input.

enum Pattern {
    case repoSlug       // ^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$
    case githubLogin    // alnum, (-?[A-Za-z0-9]){0,38}: no leading/trailing hyphen
    case model          // ^[A-Za-z0-9._:-]{0,64}$
    case searchQuery    // ^[A-Za-z0-9 ._/-]{0,80}$

    func accepts(_ s: String) -> Bool {
        switch self {
        case .repoSlug:
            let parts = s.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            return parts.allSatisfy {
                Pattern.every($0, in: Pattern.slugChars, count: 1...100)
            }
        case .githubLogin:
            return Pattern.isGithubLogin(s)
        case .model:
            return Pattern.every(s[...], in: Pattern.modelChars, count: 0...64)
        case .searchQuery:
            return Pattern.every(s[...], in: Pattern.queryChars, count: 0...80)
        }
    }

    private static let slugChars  = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    private static let loginChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
    private static let modelChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
    private static let queryChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._/-")

    private static func every(_ s: Substring, in allowed: Set<Character>, count: ClosedRange<Int>) -> Bool {
        guard count.contains(s.count) else { return false }
        return s.allSatisfy { allowed.contains($0) }
    }

    // A GitHub username is alphanumeric or single hyphens, 1-39 characters, and
    // never starts or ends with a hyphen. Charset-and-length alone (`every`
    // above) accepted "-owner", "owner-" and "owner--name", none of which
    // GitHub allows — same defect as the bash side of this rule, fixed the
    // same way: reject the hyphen placements a charset check cannot see.
    private static func isGithubLogin(_ s: String) -> Bool {
        guard (1...39).contains(s.count) else { return false }
        guard s.allSatisfy({ loginChars.contains($0) }) else { return false }
        guard s.first != "-" && s.last != "-" else { return false }
        return !s.contains("--")
    }
}
