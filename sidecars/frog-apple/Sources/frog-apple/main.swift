// frog-apple: Apple's on-device Foundation Model behind an OpenAI-compatible API, so frog (and
// anything else that speaks /v1/chat/completions) can use it like any local server.
//
//   frog-apple [--port 8912]
//
// No native tool calling: frog drives it in `json` tool mode, which arrives here as a
// `response_format` JSON schema and runs as guided generation, so every reply is a valid action.

import Foundation
import FoundationModels
import AppKit
import ImagePlayground

let modelID = "apple"
let args = CommandLine.arguments
let port = args.firstIndex(of: "--port").flatMap { args.indices.contains($0 + 1) ? UInt16(args[$0 + 1]) : nil } ?? 8912

func text(_ content: Any?) -> String {
    if let s = content as? String { return s }
    if let parts = content as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
    return ""
}

/// Instructions from the system messages; the rest of the conversation as a transcript prompt
/// (the session is rebuilt per request, so earlier turns have to travel in the prompt).
func split(_ messages: [[String: Any]]) -> (instructions: String, prompt: String) {
    var system: [String] = []
    var turns: [String] = []
    for m in messages {
        let role = m["role"] as? String ?? "user"
        let body = text(m["content"])
        switch role {
        case "system", "developer": system.append(body)
        case "assistant":
            var s = body
            for call in m["tool_calls"] as? [[String: Any]] ?? [] {
                let f = call["function"] as? [String: Any] ?? [:]
                s += "\n[called \(f["name"] as? String ?? "?") with \(f["arguments"] as? String ?? "{}")]"
            }
            turns.append("Assistant: \(s)")
        case "tool": turns.append("Tool result:\n\(body)")
        default: turns.append("User: \(body)")
        }
    }
    let prompt: String
    if turns.count == 1, let only = messages.last, (only["role"] as? String) == "user" {
        prompt = text(only["content"])
    } else {
        prompt = turns.joined(separator: "\n\n") + "\n\nContinue as the assistant."
    }
    return (system.joined(separator: "\n\n"), prompt)
}

func chunk(_ id: String, _ delta: [String: Any], finish: String? = nil) -> [String: Any] {
    ["id": id, "object": "chat.completion.chunk", "created": Int(Date().timeIntervalSince1970), "model": modelID,
     "choices": [["index": 0, "delta": delta, "finish_reason": finish as Any]]]
}

func usage(_ prompt: String, _ out: String, counted: Int?) -> [String: Any] {
    // Counted by the model's own tokenizer where the OS can (macOS 26.4); else ~4 characters
    // per token. frog calibrates its context budget from these, so a real count matters.
    let p = counted ?? (prompt.count + 3) / 4
    let c = (out.count + 3) / 4
    return ["prompt_tokens": p, "completion_tokens": c, "total_tokens": p + c]
}

/// Tokens a request takes before the reply: instructions, the prompt, and the schema guided
/// generation adds. `nil` where the OS can't count them.
func promptTokens(_ model: SystemLanguageModel, _ instructions: String, _ prompt: String, _ schema: GenerationSchema?) async -> Int? {
    guard #available(macOS 26.4, *) else { return nil }
    do {
        var n = try await model.tokenCount(for: prompt)
        if !instructions.isEmpty { n += try await model.tokenCount(for: Instructions(instructions)) }
        if let schema { n += try await model.tokenCount(for: schema) }
        return n
    } catch {
        return nil
    }
}

/// Room left for the reply: the context holds the prompt *and* what's generated, and a reply
/// allowed to run on fails at contextSize + 1 instead of stopping. A few tokens are kept back
/// for the framework's own framing.
let replyMargin = 64

struct ContextFull: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func chat(_ body: [String: Any], _ res: HTTPServer.Response) async {
    let model = SystemLanguageModel.default
    guard case .available = model.availability else {
        res.json(503, ["error": ["message": "Apple Intelligence model unavailable: \(model.availability)"]])
        return
    }
    let (instructions, prompt) = split(body["messages"] as? [[String: Any]] ?? [])
    var options = GenerationOptions()
    options.temperature = body["temperature"] as? Double
    options.maximumResponseTokens = (body["max_completion_tokens"] ?? body["max_tokens"]) as? Int
    let stream = body["stream"] as? Bool ?? false
    let id = "chatcmpl-\(UUID().uuidString.prefix(12))"
    if ProcessInfo.processInfo.environment["FROG_APPLE_DEBUG"] != nil {
        FileHandle.standardError.write(Data("--- instructions (\(instructions.count) chars)\n\(instructions.suffix(1500))\n--- prompt\n\(prompt)\n".utf8))
    }
    let session = LanguageModelSession(model: model, instructions: instructions.isEmpty ? nil : instructions)

    let format = body["response_format"] as? [String: Any]
    let schemaJSON = (format?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
    var output = ""
    var counted: Int?
    do {
        let schema = try schemaJSON.map(SchemaConverter.generationSchema)
        counted = await promptTokens(model, instructions, prompt, schema)
        if let counted {
            let room = model.contextSize - counted - replyMargin
            guard room > 0 else {
                throw ContextFull(message: "Content contains \(counted) tokens, leaving no room for a reply in the context of \(model.contextSize).")
            }
            options.maximumResponseTokens = min(options.maximumResponseTokens ?? room, room)
        }
        if let schema {
            let r = try await session.respond(to: prompt, schema: schema, options: options)
            output = r.content.jsonString
            if stream { await res.event(chunk(id, ["role": "assistant", "content": output])) }
        } else if stream {
            for try await snap in session.streamResponse(to: prompt, options: options) {
                let now = snap.content
                guard now.count > output.count, now.hasPrefix(output) else { output = now; continue }
                let delta = String(now.dropFirst(output.count))
                output = now
                if !(await res.event(chunk(id, ["role": "assistant", "content": delta]))) { return }
            }
        } else {
            output = try await session.respond(to: prompt, options: options).content
        }
    } catch {
        let message = "\(error)"
        if ProcessInfo.processInfo.environment["FROG_APPLE_DEBUG"] != nil {
            FileHandle.standardError.write(Data("--- error (prompt \(counted.map(String.init) ?? "?") tokens, reply cap \(options.maximumResponseTokens.map(String.init) ?? "none")): \(message)\n".utf8))
        }
        if stream {
            await res.event(["error": ["message": message]])
            await res.finish()
        } else {
            res.json(400, ["error": ["message": message]])
        }
        return
    }
    if ProcessInfo.processInfo.environment["FROG_APPLE_DEBUG"] != nil {
        FileHandle.standardError.write(Data("--- reply (prompt \(counted.map(String.init) ?? "?") tokens, reply cap \(options.maximumResponseTokens.map(String.init) ?? "none"))\n\(output.prefix(600))\n".utf8))
    }
    if stream {
        await res.event(chunk(id, [:], finish: "stop"))
        await res.event(["id": id, "object": "chat.completion.chunk", "choices": [], "usage": usage(prompt, output, counted: counted)])
        await res.finish()
    } else {
        res.json(200, [
            "id": id, "object": "chat.completion", "created": Int(Date().timeIntervalSince1970), "model": modelID,
            "choices": [["index": 0, "message": ["role": "assistant", "content": output], "finish_reason": "stop"]],
            "usage": usage(prompt, output, counted: counted),
        ])
    }
}

let ctx = SystemLanguageModel.default.contextSize
let server = try HTTPServer(port: port) { req, res in
    switch (req.method, req.path.split(separator: "?").first.map(String.init) ?? req.path) {
    case ("GET", "/health"): res.json(200, ["status": "ok"])
    case ("GET", "/props"): res.json(200, ["n_ctx": ctx, "default_generation_settings": ["n_ctx": ctx]])
    case ("GET", "/v1/models"):
        res.json(200, ["object": "list", "data": [["id": modelID, "object": "model", "owned_by": "apple", "max_model_len": ctx]]])
    case ("POST", "/v1/screenshots"), ("POST", "/v1/images/generations"):
        guard let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
            res.json(400, ["error": ["message": "invalid JSON"]]); return
        }
        if req.path == "/v1/screenshots" { await screenshot(body, res) }
        else { await createImages(body, res) }
    case ("POST", "/v1/chat/completions"):
        guard let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
            res.json(400, ["error": ["message": "invalid JSON"]])
            return
        }
        await chat(body, res)
    default: res.json(404, ["error": ["message": "not found"]])
    }
}
server.start()
FileHandle.standardError.write(Data("frog-apple: listening on http://127.0.0.1:\(port) (context \(ctx))\n".utf8))
// Started for the Mac app (whose engines pass `FROG_APP_PID` down), it goes when the app does:
// it's detached from the engine so later sessions reuse it, which left it running, ppid 1, after
// the app quit or crashed. Started from the CLI, it outlives the engine as before.
let appWatch: DispatchSourceProcess? = ProcessInfo.processInfo.environment["FROG_APP_PID"]
    .flatMap { pid_t($0) }
    .map { pid in
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { exit(0) }
        source.resume()
        // Already gone before the watch began (kqueue reports nothing for a dead pid).
        if kill(pid, 0) != 0, errno == ESRCH { exit(0) }
        return source
    }
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
