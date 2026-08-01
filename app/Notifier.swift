//  Notifier.swift — post the engine's notifications, wearing the Goblin's face.
//
//  WHY THIS EXISTS AT ALL.
//
//  The engine is bash under launchd, and bash's only way to raise a macOS banner is
//  `osascript -e 'display notification'`. That works, but the banner is attributed
//  to the process that posted it — com.apple.ScriptEditor2 — so every notification
//  arrived wearing Script Editor's icon. It reads like a stray system script, not
//  like the tool you installed, and there is no osascript flag that changes it:
//  only a real app bundle can put its own icon on a notification.
//
//  So the engine appends a request to ~/.goblin/notify.jsonl and this class posts
//  it. The app already watches that directory for state changes, so the queue costs
//  no new file-watching machinery. bash falls back to osascript when the app is not
//  running, on the grounds that a wrong icon beats a missing notification.
//
//  Deliberate choices:
//    * The read offset is remembered, so a restart does not replay every banner the
//      engine has ever queued. On first run we jump to the END of the file rather
//      than the start — the alternative is a wall of stale notifications the first
//      time someone launches the app after a busy day.
//    * Requests older than five minutes are dropped. "posted a review" is only
//      interesting while it is news.
//    * Authorization is requested once, lazily, and failure is silent. A tool that
//      nags for notification permission on every launch is worse than one that
//      quietly does without.

import Foundation
import UserNotifications
import os

final class Notifier {

    static let shared = Notifier()

    private let log = Logger(subsystem: "goblin.bar", category: "notify")
    private let queue = DispatchQueue(label: "goblin.notify")

    /// How far into notify.jsonl we have already read.
    private var offset: UInt64 = 0
    private var primed = false
    private var authorized: Bool?

    /// Anything older than this is history, not news.
    private let maxAge: TimeInterval = 300

    private var queueURL: URL {
        URL(fileURLWithPath: CLI.shared.home).appendingPathComponent("notify.jsonl")
    }

    // MARK: - Authorization

    /// Asked for once, lazily. If the user says no, we simply never post — the
    /// engine's osascript fallback is not reachable from here, and pestering is
    /// worse than silence.
    private func ensureAuthorized(_ done: @escaping (Bool) -> Void) {
        if let authorized { done(authorized); return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, err in
            if let err { self?.log.error("notification authorization failed: \(err.localizedDescription, privacy: .public)") }
            self?.queue.async {
                self?.authorized = granted
                done(granted)
            }
        }
    }

    // MARK: - Draining

    /// Called on every ~/.goblin change (the StateStore watcher already fires) and
    /// once at launch to establish the offset without replaying anything.
    func drain() {
        queue.async { [weak self] in self?.drainLocked() }
    }

    private func drainLocked() {
        let url = queueURL
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let end = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0

        // Truncated or rotated: start over rather than reading from a bogus offset.
        if end < offset { offset = 0 }

        // First sight of the file: adopt its end. Everything already in it happened
        // before the app was running and is not news.
        if !primed {
            primed = true
            offset = end
            return
        }
        guard end > offset else { return }

        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset = end
        guard !data.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty,
                  let bytes = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            else { continue }

            let at = (obj["at"] as? Double) ?? (obj["at"] as? NSNumber)?.doubleValue ?? now
            guard now - at <= maxAge else { continue }

            let title = (obj["title"] as? String) ?? "The Merge Goblin"
            let body = (obj["message"] as? String) ?? ""
            let sound = (obj["sound"] as? String) ?? ""
            post(title: title, body: body, sound: !sound.isEmpty)
        }
    }

    private func post(title: String, body: String, sound: Bool) {
        ensureAuthorized { [weak self] granted in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if sound { content.sound = .default }
            // Nil trigger = deliver now. The icon is the app's, automatically,
            // which is the entire point of routing through here.
            let req = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
            UNUserNotificationCenter.current().add(req) { err in
                if let err { self?.log.error("could not post: \(err.localizedDescription, privacy: .public)") }
            }
        }
    }
}
