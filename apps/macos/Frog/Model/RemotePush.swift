import Foundation

/// Tells your phone when frog needs you or is done, so you can put it down. Phones register over
/// the bridge; this watches the engines' lines and sends a push for a live question (with the
/// command or diff, and Allow / Deny) and for a finished turn (with the start of the answer).
///
/// Two ways out: the iOS Simulator directly (`xcrun simctl push`), for development, and the
/// frog relay for real phones, which holds the APNs key (it can't live in this app).
@MainActor
final class RemotePush {
    static let shared = RemotePush()

    struct Device: Codable, Hashable {
        /// "simctl" (a simulator's UDID) or "apns" (a device token).
        var transport: String
        var address: String
        var bundle: String
        /// APNs environment: "sandbox" or "production".
        var env: String?
        /// A Live Activity's push token, per session, for updates while the app is asleep.
        var activities: [String: String]? = nil
    }

    /// Where pushes for real phones go.
    static var relay: URL {
        URL(string: ProcessInfo.processInfo.environment["FROG_PUSH_RELAY"] ?? "https://frog.eco/api/push")!
    }

    private(set) var devices: [Device]

    private init() {
        let data = UserDefaults.standard.data(forKey: "remoteDevices") ?? Data()
        devices = (try? JSONDecoder().decode([Device].self, from: data)) ?? []
    }

    func register(_ device: Device) {
        var d = device
        if let old = devices.first(where: { $0.address == device.address }) { d.activities = old.activities }
        devices.removeAll { $0.address == device.address }
        devices.append(d)
        save()
        EngineProcess.log("remote: push to \(device.transport) \(device.address.prefix(8))…")
    }

    /// A Live Activity for `session` can be updated through this token.
    func activity(session: String, token: String?, device address: String) {
        guard let i = devices.firstIndex(where: { $0.address == address }) else { return }
        var map = devices[i].activities ?? [:]
        map[session] = token
        devices[i].activities = map
        save()
    }

    func forget(_ address: String) {
        devices.removeAll { $0.address == address }
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(devices), forKey: "remoteDevices")
    }

    // MARK: Deciding

    /// An engine line. Only what's happening now counts: a reopened session replays its history
    /// through the same pipe, and that's never news.
    func observe(_ line: String) {
        guard !devices.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let session = obj["session"] as? String,
              let created = (obj["created"] as? NSNumber)?.doubleValue,
              Date().timeIntervalSince1970 * 1000 - created < 30_000 else { return }
        switch obj["event"] as? String {
        case "permission_request": asked(obj, session: session)
        case "turn_ended": finished(obj, session: session)
        case "item_started", "item_completed", "turn_started": activityUpdate(obj, session: session)
        default: break
        }
    }

    private func title(_ session: String) -> (title: String, folder: String?) {
        let s = Library.shared.sessions.first { $0.id == session }
        let c = Library.shared.conversation(session)
        let title = c?.title ?? s?.displayTitle ?? "frog"
        let folder = (c?.folder).flatMap { Frog.isChat($0) ? nil : $0.lastPathComponent }
        return (title, folder)
    }

    private func asked(_ obj: [String: Any], session: String) {
        let (title, folder) = title(session)
        let name = obj["name"] as? String ?? ""
        let arg = obj["arg"] as? String ?? ""
        let subtitle: String
        let body: String
        switch name {
        case "Bash": subtitle = "wants to run a command"; body = "$ " + String(arg.prefix(300))
        case "Edit", "Write":
            subtitle = "wants to \(name == "Edit" ? "edit" : "write") \((arg as NSString).lastPathComponent)"
            body = (obj["reason"] as? String) ?? "Review the change before it's made."
        default: subtitle = "wants to use \(name)"; body = String(arg.prefix(300))
        }
        var payload: [String: Any] = [
            "aps": [
                "alert": ["title": title, "subtitle": "frog " + subtitle + (folder.map { " in \($0)" } ?? ""), "body": body],
                "category": "PERMISSION",
                "thread-id": session,
                "interruption-level": "time-sensitive",
                "sound": "default",
                "mutable-content": 1,
            ],
            "session": session,
            "permission": obj["id"] as? String ?? "",
            "name": name,
            "arg": String(arg.prefix(300)),
            "always": obj["always"] as? String ?? "",
        ]
        if let preview = obj["preview"] as? [String: Any] { payload["preview"] = Self.trim(preview) }
        // APNs takes 4 KB; the diff is the first thing to go.
        if (try? JSONSerialization.data(withJSONObject: payload))?.count ?? 0 > 3800 { payload["preview"] = nil }
        send(payload, collapse: "perm-\(session)")
        let creating = (obj["preview"] as? [String: Any])?["created"] as? Bool ?? false
        let question = PermissionRequest.question(name: name, arg: arg, outsideSandbox: obj["reason"] is String, creating: creating)
        sendActivity(session: session, event: "update", state: [
            "mood": "waiting", "activity": question, "steps": steps[session, default: 0],
            "waiting": true, "permission": obj["id"] as? String ?? "",
        ])
    }

    private func finished(_ obj: [String: Any], session: String) {
        let (title, _) = title(session)
        let reason = (obj["reason"] as? [String: Any])?["type"] as? String ?? "complete"
        let answer = Library.shared.conversation(session)?.turns.last?.items.last { $0.kind == .message }?.text ?? ""
        let line = answer.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
        let body: String
        switch reason {
        case "complete": body = line.isEmpty ? "Done." : String(line.prefix(180))
        case "cancelled": body = "Stopped."
        case "denied": body = "Stopped: you said no."
        case "error":
            let e = (obj["reason"] as? [String: Any])?["error"] as? [String: Any]
            body = "Stopped: " + ((e?["message"] as? String) ?? "something went wrong")
        default: body = "Stopped."
        }
        send([
            "aps": ["alert": ["title": title, "body": body], "category": "DONE", "thread-id": session, "sound": "default"],
            "session": session,
        ], collapse: "done-\(session)")
        activityEnd(session: session, summary: body)
    }

    /// A diff cut down to what a notification can show.
    private static func trim(_ diff: [String: Any]) -> [String: Any] {
        var out = diff
        var budget = 24
        let hunks = (diff["hunks"] as? [[String: Any]] ?? []).compactMap { h -> [String: Any]? in
            guard budget > 0 else { return nil }
            let lines = (h["lines"] as? [[String: Any]] ?? []).prefix(budget).map { l -> [String: Any] in
                var l = l
                if let t = l["text"] as? String, t.count > 100 { l["text"] = String(t.prefix(100)) }
                return l
            }
            budget -= lines.count
            return ["lines": Array(lines)]
        }
        out["hunks"] = hunks
        return out
    }

    // MARK: Live Activity

    private var steps: [String: Int] = [:]

    /// The lock screen's live view of a turn, moved along while the phone's app is asleep.
    private func activityUpdate(_ obj: [String: Any], session: String) {
        guard devices.contains(where: { $0.activities?[session] != nil }) else { return }
        let event = obj["event"] as? String
        if event == "turn_started" { steps[session] = 0 }
        var activity = "Thinking…"
        if event == "item_started", let kind = obj["kind"] as? [String: Any], kind["type"] as? String == "tool_call" {
            activity = Self.verb(kind["name"] as? String ?? "", kind["arg"] as? String ?? "")
        } else if event == "item_completed", (obj["item"] as? [String: Any])?["type"] as? String == "tool_call" {
            steps[session, default: 0] += 1
        }
        sendActivity(session: session, event: "update", state: [
            "mood": event == "item_started" ? "working" : "thinking",
            "activity": activity,
            "steps": steps[session, default: 0],
        ])
    }

    private func activityEnd(session: String, summary: String) {
        sendActivity(session: session, event: "end", state: [
            "mood": "done", "activity": summary, "steps": steps[session, default: 0],
        ])
    }

    /// The step in hand, in the words the transcript uses ("Running the tests…").
    static func verb(_ name: String, _ arg: String) -> String {
        ActivityWords.now(ItemState(id: "", kind: .tool(name: name, arg: arg)))
    }

    private func sendActivity(session: String, event: String, state: [String: Any]) {
        for d in devices {
            guard let token = d.activities?[session] else { continue }
            var aps: [String: Any] = [
                "timestamp": Int(Date().timeIntervalSince1970),
                "event": event,
                "content-state": state,
            ]
            if event == "end" { aps["dismissal-date"] = Int(Date().timeIntervalSince1970) + 15 * 60 }
            deliver(["aps": aps], to: d, collapse: nil, activityToken: token)
        }
    }

    // MARK: Delivering

    private func send(_ payload: [String: Any], collapse: String?) {
        for d in devices { deliver(payload, to: d, collapse: collapse, activityToken: nil) }
    }

    private func deliver(_ payload: [String: Any], to d: Device, collapse: String?, activityToken: String?) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        switch d.transport {
        case "simctl":
            // Simulators take the payload straight from a file; Live Activity updates aren't
            // simulated this way, so those only go to real phones.
            guard activityToken == nil else { return }
            var p = payload
            p["Simulator Target Bundle"] = d.bundle
            let file = FileManager.default.temporaryDirectory.appending(path: "frog-push-\(UUID().uuidString).apns")
            guard let body = try? JSONSerialization.data(withJSONObject: p), (try? body.write(to: file)) != nil else { return }
            Task.detached {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                proc.arguments = ["simctl", "push", d.address, d.bundle, file.path]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try? proc.run()
                proc.waitUntilExit()
                try? FileManager.default.removeItem(at: file)
            }
        case "apns":
            var req = URLRequest(url: Self.relay)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = [
                "token": activityToken ?? d.address,
                "env": d.env ?? "production",
                "topic": d.bundle + (activityToken == nil ? "" : ".push-type.liveactivity"),
                "push_type": activityToken == nil ? "alert" : "liveactivity",
                "payload": String(decoding: data, as: UTF8.self),
            ]
            if let collapse { body["collapse_id"] = collapse }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            let address = d.address
            URLSession.shared.dataTask(with: req) { _, response, _ in
                // 410: the app was deleted or pushes turned off; stop sending to it.
                guard (response as? HTTPURLResponse)?.statusCode == 410, activityToken == nil else { return }
                Task { @MainActor in RemotePush.shared.forget(address) }
            }.resume()
        default:
            break
        }
    }
}
