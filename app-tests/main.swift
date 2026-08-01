//  app-tests/main.swift — the allowlist's test suite.
//
//  A plain executable, not XCTest: XCTest needs xcodebuild or swift-test, and the
//  whole point of this app is that it builds with the Command Line Tools alone.
//  Compile it together with app/Command.swift and run it:
//
//      swiftc -o /tmp/goblin-app-tests app/Command.swift app-tests/main.swift
//      /tmp/goblin-app-tests
//
//  or just: goblin app test   (see lib/app.sh)
//
//  Exits non-zero on the first-to-last failure, printing which assertion failed
//  and where.

import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ what: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("  ✗ \(what)   [main.swift:\(line)]")
    }
}

func argv(of body: [String: Any], line: Int = #line) -> [String]? {
    do {
        let plan = try Command.parse(body: body).validatedPlan()
        if case .cli(let a, _, _, _) = plan { return a }
        return nil
    } catch {
        failures += 1
        checks += 1
        print("  ✗ expected to parse, got refusal: \(error)   [main.swift:\(line)]")
        return nil
    }
}

/// Asserts the message maps to exactly this argv.
func expect(_ body: [String: Any], _ want: [String], line: Int = #line) {
    checks += 1
    do {
        let plan = try Command.parse(body: body).validatedPlan()
        guard case .cli(let got, _, _, _) = plan else {
            failures += 1
            print("  ✗ \(body["cmd"] ?? "?") produced a local action, wanted argv   [main.swift:\(line)]")
            return
        }
        if got != want {
            failures += 1
            print("  ✗ \(body["cmd"] ?? "?")")
            print("      want: \(want)")
            print("      got:  \(got)   [main.swift:\(line)]")
        }
    } catch {
        failures += 1
        print("  ✗ \(body["cmd"] ?? "?") refused unexpectedly: \(error)   [main.swift:\(line)]")
    }
}

/// Asserts the message maps to exactly this local action.
func expectLocal(_ body: [String: Any], _ want: LocalAction, line: Int = #line) {
    checks += 1
    do {
        let plan = try Command.parse(body: body).validatedPlan()
        guard case .local(let got) = plan, got == want else {
            failures += 1
            print("  ✗ \(body["cmd"] ?? "?") did not produce \(want)   [main.swift:\(line)]")
            return
        }
    } catch {
        failures += 1
        print("  ✗ \(body["cmd"] ?? "?") refused unexpectedly: \(error)   [main.swift:\(line)]")
    }
}

/// Asserts the message is refused. `why` is only for the failure message.
func expectRefused(_ body: Any, _ why: String, line: Int = #line) {
    checks += 1
    do {
        let plan = try Command.parse(body: body).validatedPlan()
        failures += 1
        print("  ✗ should have refused \(why), but got \(plan)   [main.swift:\(line)]")
    } catch {
        // good
    }
}

func msg(_ cmd: String, _ args: [String: Any]? = nil) -> [String: Any] {
    var d: [String: Any] = ["v": 1, "cmd": cmd]
    if let args { d["args"] = args }
    return d
}

// ---------------------------------------------------------------- argv map ---
print("argv mapping")

expect(msg("power", ["on": true]),  ["on"])
expect(msg("power", ["on": false]), ["off"])
expect(msg("pause"),  ["pause"])
expect(msg("resume"), ["resume"])
expect(msg("snooze", ["kind": "hour"]),     ["snooze1h"])
expect(msg("snooze", ["kind": "tomorrow"]), ["snoozetomorrow"])
expect(msg("snooze", ["kind": "clear"]),    ["clearsnooze"])

expect(msg("reviewNow"), ["run-now"])
expect(msg("dryRun"),    ["panel", "dry-run"])

expect(msg("setMaxReviewsPerDay", ["value": 0]),   ["panel", "set", "max-per-day", "0"])
expect(msg("setMaxReviewsPerDay", ["value": 500]), ["panel", "set", "max-per-day", "500"])
expect(msg("setMaxReviewsPerRun", ["value": 5]),   ["panel", "set", "max-per-run", "5"])
expect(msg("setMaxFindings", ["value": 25]),       ["panel", "set", "max-findings", "25"])
expect(msg("setIntervalMinutes", ["value": 15]),   ["panel", "set", "interval-minutes", "15"])

expect(msg("setVerdictMode", ["value": "comment"]),         ["panel", "set", "verdict-mode", "comment"])
expect(msg("setVerdictMode", ["value": "request-changes"]), ["panel", "set", "verdict-mode", "request-changes"])
expect(msg("setVerdictMode", ["value": "full"]),            ["panel", "set", "verdict-mode", "full"])
expect(msg("setAllowApprove", ["value": true]),             ["panel", "set", "allow-approve", "on"])
expect(msg("setAllowApprove", ["value": false]),            ["panel", "set", "allow-approve", "off"])

// every flag key must map to a kebab-case name and nothing else
let flagNames: [FlagKey: String] = [
    .incrementalReview: "incremental-review",
    .postCommitStatus:  "post-commit-status",
    .fleetAssignment:   "fleet-assignment",
    .notifyStarted:     "notify-started",
    .notifyPosted:      "notify-posted",
    .notifyFailed:      "notify-failed",
    .notifyBudget:      "notify-budget",
    .notifySound:       "notify-sound",
    .skipIfHumanReviewed: "skip-if-human-reviewed",
]
check(flagNames.count == FlagKey.allCases.count, "the flag-name table covers every FlagKey")
for key in FlagKey.allCases {
    expect(msg("setFlag", ["key": key.rawValue, "value": true]),
           ["panel", "set", "flag", flagNames[key] ?? "??", "on"])
    expect(msg("setFlag", ["key": key.rawValue, "value": false]),
           ["panel", "set", "flag", flagNames[key] ?? "??", "off"])
}

for id in ProviderId.allCases {
    expect(msg("setProvider", ["id": id.rawValue]), ["provider", "use", id.rawValue])
}
expect(msg("setProviderModel", ["provider": "claude", "model": "sonnet"]),
       ["panel", "set", "provider-model", "claude", "sonnet"])
expect(msg("setProviderModel", ["provider": "codex", "model": ""]),
       ["panel", "set", "provider-model", "codex", ""])
expect(msg("setProviderModel", ["provider": "cursor", "model": "gpt-5.1-codex-max:high"]),
       ["panel", "set", "provider-model", "cursor", "gpt-5.1-codex-max:high"])

expect(msg("repoAdd",    ["slug": "Kiril-P/merge-goblin"]), ["repos", "add", "Kiril-P/merge-goblin"])
expect(msg("repoRemove", ["slug": "Kiril-P/merge-goblin"]), ["repos", "rm", "Kiril-P/merge-goblin"])
expect(msg("repoEnable", ["slug": "a/b", "on": true]),      ["repos", "enable", "a/b"])
expect(msg("repoEnable", ["slug": "a/b", "on": false]),     ["repos", "disable", "a/b"])

expect(msg("setIdentity", ["login": "Kiril-P"]), ["panel", "set", "identity", "Kiril-P"])
expect(msg("fixAccount"), ["fix-account"])

expect(msg("doctor"),               ["doctor", "--json"])
expect(msg("doctor", ["fix": false]), ["doctor", "--json"])
expect(msg("doctor", ["fix": true]),  ["doctor", "--fix", "--json"])
for action in AgentAction.allCases {
    expect(msg("agent", ["action": action.rawValue]), ["agent", action.rawValue])
}

expect(msg("state"), ["status", "--json"])
expect(msg("inbox"), ["inbox", "--json"])
expect(msg("inbox", ["refresh": true]), ["inbox", "--refresh", "--json"])
expect(msg("accounts"), ["accounts", "--json"])
expect(msg("providers"), ["provider", "list", "--json"])
expect(msg("providers", ["refresh": true]), ["provider", "list", "--refresh", "--json"])
expect(msg("repoSearch", ["query": "goblin"]),
       ["repo-search", "--json", "--limit", "30", "--query", "goblin"])
expect(msg("repoSearch", ["query": "", "limit": 200]),
       ["repo-search", "--json", "--limit", "200", "--query", ""])

expect(msg("wizardState"), ["wizard", "state", "--json"])
expect(msg("wizardComplete"), ["wizard", "complete"])

expect(msg("loginItem", ["on": true]),  ["app", "login-item", "on"])
expect(msg("loginItem", ["on": false]), ["app", "login-item", "off"])

// ------------------------------------------------------------ local actions ---
print("local actions (never subprocesses)")
expectLocal(msg("openLog"),    .openLog)
expectLocal(msg("openConfig"), .openConfig)
expectLocal(msg("copyDiagnostics"), .copyDiagnostics)
expectLocal(msg("openURL", ["url": "https://github.com/Kiril-P/merge-goblin/pull/1"]),
            .openURL("https://github.com/Kiril-P/merge-goblin/pull/1"))

// ---------------------------------------------------------------- refusals ---
print("refusals")

// protocol frame
expectRefused("power", "a bare string body")
expectRefused([1, 2, 3], "an array body")
expectRefused(["cmd": "pause"], "a missing v")
expectRefused(["v": 2, "cmd": "pause"], "v=2")
expectRefused(["v": "1", "cmd": "pause"], "v as a string")
expectRefused(["v": 1], "a missing cmd")
expectRefused(["v": 1, "cmd": "pause", "token": "x"], "an extra top-level key")
expectRefused(["v": 1, "cmd": "definitelyNotAVerb"], "an unknown verb")
expectRefused(["v": 1, "cmd": "power", "args": [true]], "args as an array")
expectRefused(["v": 1, "cmd": "pause", "args": "on"], "args as a string")

// the hole the python server had: no config path, ever
expectRefused(["v": 1, "cmd": "config", "args": ["path": ".providers.claude.bin", "value": "/tmp/x"]],
              "a config verb")
expectRefused(msg("setProviderModel", ["provider": "claude", "bin": "/tmp/evil"]),
              "a provider binary path")
expectRefused(msg("setFlag", ["key": "providers.claude.bin", "value": true]),
              "a flag key that is really a config path")

// unknown args keys are a refusal, not ignored
expectRefused(msg("pause", ["extra": 1]), "an unknown key on a no-arg verb")
expectRefused(msg("power", ["on": true, "also": "x"]), "an unknown extra key")
expectRefused(msg("doctor", ["fix": true, "deep": true]), "an unknown optional key")
expectRefused(msg("repoAdd", ["slug": "a/b", "force": true]), "an unknown key on repoAdd")

// missing / wrong-typed required args
expectRefused(msg("power"), "power with no on")
expectRefused(msg("power", ["on": 1]), "on as a number")
expectRefused(msg("power", ["on": "true"]), "on as a string")
expectRefused(msg("snooze"), "snooze with no kind")
expectRefused(msg("snooze", ["kind": "forever"]), "an unknown snooze kind")
expectRefused(msg("agent", ["action": "restart"]), "an unknown agent action")
expectRefused(msg("setVerdictMode", ["value": "requestChanges"]), "a camelCase verdict mode")
expectRefused(msg("setProvider", ["id": "copilot"]), "an unknown provider")

// numeric ranges
expectRefused(msg("setMaxReviewsPerDay", ["value": -1]),  "max-per-day below range")
expectRefused(msg("setMaxReviewsPerDay", ["value": 501]), "max-per-day above range")
expectRefused(msg("setMaxReviewsPerRun", ["value": 0]),   "max-per-run of 0")
expectRefused(msg("setMaxReviewsPerRun", ["value": 51]),  "max-per-run above range")
expectRefused(msg("setMaxFindings", ["value": 0]),        "max-findings of 0")
expectRefused(msg("setMaxFindings", ["value": 201]),      "max-findings above range")
expectRefused(msg("setIntervalMinutes", ["value": 0]),    "interval of 0")
expectRefused(msg("setIntervalMinutes", ["value": 1441]), "interval above a day")
expectRefused(msg("setMaxFindings", ["value": 2.5]),      "a fractional count")
expectRefused(msg("setMaxFindings", ["value": "25"]),     "a numeric string")
expectRefused(msg("setMaxFindings", ["value": true]),     "a boolean count")
expectRefused(msg("repoSearch", ["query": "x", "limit": 0]),   "a limit of 0")
expectRefused(msg("repoSearch", ["query": "x", "limit": 201]), "a limit above range")

// string patterns
expectRefused(msg("repoAdd", ["slug": "noslash"]), "a slug with no owner")
expectRefused(msg("repoAdd", ["slug": "a/b/c"]), "a slug with two slashes")
expectRefused(msg("repoAdd", ["slug": "a b/c"]), "a slug with a space")
expectRefused(msg("repoAdd", ["slug": "../../etc/passwd"]), "a traversal slug")
expectRefused(msg("repoAdd", ["slug": "a/b;rm -rf /"]), "a slug with a shell metacharacter")
expectRefused(msg("repoAdd", ["slug": "a/b\u{0000}c"]), "a slug with a NUL")
expectRefused(msg("repoAdd", ["slug": "a/b\nc"]), "a slug with a newline")
expectRefused(msg("repoAdd", ["slug": "/b"]), "a slug with an empty owner")
expectRefused(msg("repoAdd", ["slug": "a/"]), "a slug with an empty name")
expectRefused(msg("repoAdd", ["slug": String(repeating: "a", count: 101) + "/b"]), "an over-long owner")
expectRefused(msg("setIdentity", ["login": ""]), "an empty login")
expectRefused(msg("setIdentity", ["login": "has space"]), "a login with a space")
expectRefused(msg("setIdentity", ["login": "a_b"]), "a login with an underscore")
expectRefused(msg("setIdentity", ["login": String(repeating: "a", count: 40)]), "an over-long login")
expectRefused(msg("setProviderModel", ["provider": "claude", "model": "a b"]), "a model with a space")
expectRefused(msg("setProviderModel", ["provider": "claude", "model": "$(id)"]), "a model with a subshell")
expectRefused(msg("setProviderModel", ["provider": "claude",
                                       "model": String(repeating: "m", count: 65)]), "an over-long model")
expectRefused(msg("repoSearch", ["query": "a;b"]), "a query with a semicolon")
expectRefused(msg("repoSearch", ["query": String(repeating: "q", count: 81)]), "an over-long query")

// no argv element may look like a flag
expectRefused(msg("repoAdd", ["slug": "-x/y"]), "a slug that would be read as a flag")
expectRefused(msg("repoRemove", ["slug": "--upload-pack=x/y"]), "a slug that is a git option")
expectRefused(msg("setIdentity", ["login": "-me"]), "a login that would be read as a flag")
expectRefused(msg("repoSearch", ["query": "--help"]), "a query that would be read as a flag")
expectRefused(msg("setProviderModel", ["provider": "claude", "model": "-foo"]),
              "a model that would be read as a flag")

// urls
expectRefused(msg("openURL", ["url": "http://example.com"]), "a plain-http url")
expectRefused(msg("openURL", ["url": "file:///etc/passwd"]), "a file url")
expectRefused(msg("openURL", ["url": "javascript:alert(1)"]), "a javascript url")
expectRefused(msg("openURL", ["url": "https://"]), "an https url with no host")
expectRefused(msg("openURL", ["url": "HTTPS://example.com"]), "an upper-cased scheme (prefix check is exact)")
expectRefused(msg("openURL", ["url": "https://example.com\nX: y"]), "a url with a newline")
expectRefused(msg("openURL", ["url": "https://example.com/" + String(repeating: "a", count: 3000)]),
              "an over-long url")
expectRefused(msg("openURL"), "openURL with no url")

// size
var huge: [String: Any] = ["v": 1, "cmd": "repoAdd"]
huge["args"] = ["slug": String(repeating: "a", count: 9000) + "/b"]
expectRefused(huge, "a body over 8 KiB")
check(Command.maxBodyBytes == 8 * 1024, "the size cap is 8 KiB")

// a body that is exactly at the edge still parses if it is otherwise valid
expect(msg("repoAdd", ["slug": String(repeating: "a", count: 100) + "/b"]),
       ["repos", "add", String(repeating: "a", count: 100) + "/b"])

// ------------------------------------------------- structural invariants ---
print("structural invariants")

// Every verb in the advertised list must parse (with plausible args) or at least
// not be an "unknown command" — otherwise window.goblin advertises a dead verb.
let plausibleArgs: [String: [String: Any]] = [
    "power": ["on": true],
    "snooze": ["kind": "clear"],
    "setMaxReviewsPerDay": ["value": 10],
    "setMaxReviewsPerRun": ["value": 5],
    "setMaxFindings": ["value": 25],
    "setIntervalMinutes": ["value": 15],
    "setVerdictMode": ["value": "comment"],
    "setAllowApprove": ["value": false],
    "setFlag": ["key": "notifySound", "value": true],
    "setProvider": ["id": "claude"],
    "setProviderModel": ["provider": "claude", "model": "sonnet"],
    "repoAdd": ["slug": "a/b"],
    "repoRemove": ["slug": "a/b"],
    "repoEnable": ["slug": "a/b", "on": true],
    "setIdentity": ["login": "octocat"],
    "repoSearch": ["query": "goblin", "limit": 30],
    "loginItem": ["on": true],
    "openURL": ["url": "https://example.com"],
    "agent": ["action": "start"],
]
for verb in Command.verbs {
    checks += 1
    do {
        _ = try Command.parse(body: msg(verb, plausibleArgs[verb])).validatedPlan()
    } catch {
        failures += 1
        print("  ✗ advertised verb '\(verb)' does not parse: \(error)   [main.swift:\(#line)]")
    }
}

// The flag whitelist must stay tiny and must not contain anything a value could
// legitimately equal.
check(Command.allowedFlagLiterals.allSatisfy { $0.hasPrefix("--") },
      "every whitelisted flag literal starts with --")
check(Command.allowedFlagLiterals.count <= 6, "the flag-literal whitelist stays small")

// Fuzz-ish sweep: no reachable argv may contain a shell metacharacter, a NUL, a
// newline, or an unwhitelisted leading dash.
let sweep: [[String: Any]] = Command.verbs.map { msg($0, plausibleArgs[$0]) }
for body in sweep {
    guard let a = argv(of: body) else { continue }
    checks += 1
    let bad = a.filter { element in
        element.contains(where: { "\0\n\r;&|`$<>(){}[]*?!\\\"'".contains($0) })
            || (element.hasPrefix("-") && !Command.allowedFlagLiterals.contains(element))
    }
    if !bad.isEmpty {
        failures += 1
        print("  ✗ \(body["cmd"] ?? "?") built a suspicious argv element: \(bad)   [main.swift:\(#line)]")
    }
}

// Nothing may reach the CLI as `config`, `run`, `ui`, `migrate` or `log`: those
// are either unbounded, long-running, or replaced by a narrower verb.
let forbiddenFirstWords: Set<String> = ["config", "run", "ui", "panel-server", "migrate", "log", "help"]
for body in sweep {
    guard let a = argv(of: body), let head = a.first else { continue }
    checks += 1
    if forbiddenFirstWords.contains(head) {
        failures += 1
        print("  ✗ \(body["cmd"] ?? "?") invokes the forbidden verb '\(head)'   [main.swift:\(#line)]")
    }
}

// ------------------------------------------------------------------ report ---
print("")
if failures == 0 {
    print("  \(checks) assertions, all passing")
    exit(0)
} else {
    print("  \(failures) of \(checks) assertions FAILED")
    exit(1)
}
