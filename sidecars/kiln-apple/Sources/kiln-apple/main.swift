// kiln-apple: Apple's on-device Foundation Model behind an OpenAI-compatible API, so kiln (and
// anything else that speaks /v1/chat/completions) can use it like any local server.
//
//   kiln-apple [--port 8912]
//
// No native tool calling: kiln drives it in `json` tool mode, which arrives here as a
// `response_format` JSON schema and runs as guided generation, so every reply is a valid action.

import Foundation
import FoundationModels

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

func usage(_ prompt: String, _ out: String) -> [String: Any] {
    // The framework doesn't report token counts; ~4 characters per token.
    let (p, c) = ((prompt.count + 3) / 4, (out.count + 3) / 4)
    return ["prompt_tokens": p, "completion_tokens": c, "total_tokens": p + c]
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
    if ProcessInfo.processInfo.environment["KILN_APPLE_DEBUG"] != nil {
        FileHandle.standardError.write(Data("--- instructions (\(instructions.count) chars)\n\(instructions.suffix(1500))\n--- prompt\n\(prompt)\n".utf8))
    }
    let session = LanguageModelSession(model: model, instructions: instructions.isEmpty ? nil : instructions)

    let format = body["response_format"] as? [String: Any]
    let schemaJSON = (format?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
    var output = ""
    do {
        if let schemaJSON {
            let schema = try SchemaConverter.generationSchema(schemaJSON)
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
        if stream {
            await res.event(["error": ["message": message]])
            await res.finish()
        } else {
            res.json(400, ["error": ["message": message]])
        }
        return
    }
    if stream {
        await res.event(chunk(id, [:], finish: "stop"))
        await res.event(["id": id, "object": "chat.completion.chunk", "choices": [], "usage": usage(prompt, output)])
        await res.finish()
    } else {
        res.json(200, [
            "id": id, "object": "chat.completion", "created": Int(Date().timeIntervalSince1970), "model": modelID,
            "choices": [["index": 0, "message": ["role": "assistant", "content": output], "finish_reason": "stop"]],
            "usage": usage(prompt, output),
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
FileHandle.standardError.write(Data("kiln-apple: listening on http://127.0.0.1:\(port) (context \(ctx))\n".utf8))
dispatchMain()
