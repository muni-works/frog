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
    static let defaultRelay = URL(string: "https://frog.toys/api/push")!
    /// A malformed FROG_PUSH_RELAY falls back to the default instead of crashing.
    static var relay: URL {
        relay(ProcessInfo.processInfo.environment["FROG_PUSH_RELAY"])
    }
    static func relay(_ override: String?) -> URL {
        guard let s = override, !s.isEmpty, let url = URL(string: s), url.scheme != nil else { return defaultRelay }
        return url
    }

    /// What the relay wants to hear from a Mac (`PUSH_RELAY_SECRET` there): Settings › General,
    /// or FROG_PUSH_SECRET. Empty, pushes to real phones stay home; the Simulator path doesn't
    /// need it. One shared secret is the beta's answer; a per-Mac secret minted at pairing is the
    /// plan (docs/ios/surfaces.md).
    static let secretKey = "pushRelaySecret"
    static var secret: String {
        ProcessInfo.processInfo.environment["FROG_PUSH_SECRET"] ?? UserDefaults.standard.string(forKey: secretKey) ?? ""
    }

    private(set) var devices: [Device]
    private var warnedNoSecret = false

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
        case "question": choosing(obj, session: session)
        // A finished turn is not a push: it's already on the Mac's screen, and the model
        // decides what's worth reaching a phone with. Its `Notify` goes out through
        // `MacEffects.notified` (which has the conversation's title), not from this line:
        // one path, one push.
        // The Live Activity still follows the turn, because it's the lock screen's state, not
        // an alert.
        case "turn_ended": activityEnded(obj, session: session)
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
        // The request itself, so the phone shows the question as the Mac does (QuestionBody).
        var request: [String: Any] = ["id": obj["id"] ?? "", "item": obj["item"] ?? "", "name": name,
                                      "arg": String(arg.prefix(300)), "always": obj["always"] ?? ""]
        if let reason = obj["reason"] { request["reason"] = reason }
        if let preview = obj["preview"] as? [String: Any] { request["preview"] = Self.trim(preview) }
        payload["request"] = request
        send(payload, collapse: "perm-\(session)")
        let creating = (obj["preview"] as? [String: Any])?["created"] as? Bool ?? false
        let question = PermissionRequest.question(name: name, arg: arg, outsideSandbox: obj["reason"] is String, creating: creating)
        sendActivity(session: session, event: "update", state: [
            "mood": "waiting", "activity": question, "steps": steps[session, default: 0],
            "waiting": true, "permission": obj["id"] as? String ?? "",
        ])
    }

    /// frog's own question (the `Ask` tool): the options in the body; answered in the app, or on the watch.
    private func choosing(_ obj: [String: Any], session: String) {
        let (title, folder) = title(session)
        let options = (obj["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        send([
            "aps": [
                "alert": ["title": title, "subtitle": "frog asks" + (folder.map { " in \($0)" } ?? ""),
                          "body": String((obj["question"] as? String ?? "").prefix(300))
                              + (options.isEmpty ? "" : "\n" + options.prefix(4).joined(separator: " · "))],
                "category": "ASK",
                "thread-id": session,
                "interruption-level": "time-sensitive",
                "sound": "default",
            ],
            "session": session,
            "ask": obj["id"] as? String ?? "",
        ], collapse: "ask-\(session)")
    }

    /// The model asked for the person's attention (its `Notify` tool), from `MacEffects`: the
    /// only alert a turn can raise on the phone. A finished reply isn't one, so nothing arrives
    /// unless the model said it mattered. Urgency picks the interruption level — `attention`
    /// is time-sensitive with a sound, `done` is active (a banner, no breakthrough), `silent`
    /// is passive with no sound: a quiet entry in Notification Center, no interruption at all.
    func notify(_ note: NotifyNote, session: String?, project: String?) {
        guard let session, !devices.isEmpty else { return }
        sendNotify(title: note.title ?? title(session).title, body: note.body,
                   urgency: note.urgency, folder: project ?? title(session).folder, session: session)
    }

    /// One `Notify` to every paired phone. Each is its own news, so they don't collapse into
    /// one another the way a permission card's refreshes do.
    private func sendNotify(title: String, body: String, urgency: NotifyUrgency,
                            folder: String?, session: String) {
        guard let payload = Self.notifyPayload(title: title, body: body, urgency: urgency,
                                               folder: folder, session: session)
        else { return }
        send(payload, collapse: nil)
    }

    /// The APNs body for a `Notify`, as iOS reads it: the category the phone registered
    /// (NOTIFY), the interruption level each urgency maps to, and no sound at all for
    /// `silent`. Pure, so the mapping is testable without a phone.
    static func notifyPayload(title: String, body: String, urgency: NotifyUrgency,
                              folder: String?, session: String) -> [String: Any]? {
        let body = String(body.prefix(300))
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let (level, sound): (String, String?) = switch urgency {
        case .attention: ("time-sensitive", "default")
        case .done: ("active", "default")
        case .silent: ("passive", nil)
        }
        var alert: [String: Any] = ["title": title, "body": body]
        if let folder { alert["subtitle"] = "frog in \(folder)" }
        var aps: [String: Any] = [
            "alert": alert,
            "category": "NOTIFY",
            "thread-id": session,
            "interruption-level": level,
        ]
        // `silent` carries no sound at all: that's what "no interruption" means on iOS.
        if let sound { aps["sound"] = sound }
        return ["aps": aps, "session": session, "urgency": urgency.rawValue]
    }

    /// The turn ended: close its Live Activity (the lock screen's state), and push nothing.
    /// A Live Activity only exists because the person added it to that session, so ending it
    /// is what they asked for; an alert on every turn end is what they didn't.
    private func activityEnded(_ obj: [String: Any], session: String) {
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

    /// An alert to every phone: sealed for real ones (the relay and Apple see a placeholder),
    /// as is for the Simulator on this Mac.
    private func send(_ payload: [String: Any], collapse: String?) {
        let sealed = Self.sealed(payload, code: RemoteBridge.token)
        for d in devices {
            let p = d.transport == "apns" ? sealed : Self.fitted(payload)
            guard let p else { continue }
            deliver(p, to: d, collapse: collapse, activityToken: nil)
        }
    }

    /// APNs takes 4 KB; the diff is the first thing to go, then the request's detail.
    private static func fitted(_ payload: [String: Any], limit: Int = 3800) -> [String: Any]? {
        var p = payload
        for strip in [[], ["preview"], ["preview", "card"], ["*"]] {
            if let data = try? JSONSerialization.data(withJSONObject: p), data.count <= limit { return p }
            guard var request = p["request"] as? [String: Any] else { break }
            if strip == ["*"] { p["request"] = nil; p["arg"] = (p["arg"] as? String).map { String($0.prefix(120)) }; continue }
            for k in strip { request[k] = nil }
            p["request"] = request
        }
        if let data = try? JSONSerialization.data(withJSONObject: p), data.count <= limit { return p }
        return nil
    }

    /// `payload` sealed for the phone paired with `code` (`PushCrypto`), inside what iOS needs in
    /// the clear: the category, thread and sound as given, `mutable-content` so the phone's
    /// extension runs, and a placeholder alert for a phone that can't open it.
    static func sealed(_ payload: [String: Any], code: String, limit: Int = 4000) -> [String: Any]? {
        guard !code.isEmpty, let aps = payload["aps"] as? [String: Any] else { return nil }
        var outerAps: [String: Any] = ["alert": ["title": "frog", "body": placeholder(category: aps["category"] as? String)],
                                       "mutable-content": 1]
        for k in ["category", "thread-id", "sound", "interruption-level"] where aps[k] != nil { outerAps[k] = aps[k] }
        // Sealing and base64 cost about a third: fit the plain payload into what's left.
        var budget = Int(Double(limit - 220) * 0.74)
        while budget > 400 {
            guard let inner = fitted(payload, limit: budget),
                  let data = try? JSONSerialization.data(withJSONObject: inner),
                  let enc = try? PushCrypto.seal(data, code: code) else { return nil }
            let outer: [String: Any] = ["aps": outerAps, PushCrypto.field: enc, "v": PushCrypto.version]
            if (try? JSONSerialization.data(withJSONObject: outer))?.count ?? .max <= limit { return outer }
            budget -= 300
        }
        return nil
    }

    /// What a phone shows when it can't open the push: enough to know to look at the Mac.
    private static func placeholder(category: String?) -> String {
        switch category {
        case "PERMISSION": "frog needs you"
        case "ASK": "frog has a question"
        case "DONE": "frog finished"
        default: "frog"
        }
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
            let secret = Self.secret
            guard !secret.isEmpty else {
                if !warnedNoSecret { EngineProcess.log("remote: no push relay secret; set it in Settings › General") }
                warnedNoSecret = true
                return
            }
            var req = URLRequest(url: Self.relay)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
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
            URLSession.shared.dataTask(with: req) { body, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status != 200 {
                    let why = body.flatMap { String(data: $0, encoding: .utf8) } ?? error?.localizedDescription ?? ""
                    EngineProcess.log("remote: push relay said \(status) \(why.prefix(200))")
                }
                // 410: the app was deleted or pushes turned off; stop sending to it.
                guard status == 410, activityToken == nil else { return }
                Task { @MainActor in RemotePush.shared.forget(address) }
            }.resume()
        default:
            break
        }
    }
}
