#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import WebKit

// MARK: - Elicitation

/// An MCP server asking the user for something mid-call: a small form built from the server's
/// flat JSON Schema, or a link to finish in the browser (sign-in, payment).
struct ElicitationCard: View {
    @Environment(\.openURL) private var openURL
    let request: Elicitation
    let conversation: Conversation
    @State private var values: [String: String] = [:]
    @State private var flags: [String: Bool] = [:]

    private struct Field: Identifiable {
        var id: String { key }
        let key: String
        let title: String
        let help: String?
        let type: String
        let options: [(value: String, title: String)]
        let required: Bool
        let fallback: JSONValue?
    }

    private var fields: [Field] {
        guard case .object(let props)? = request.schema?["properties"] else { return [] }
        let required = Set(request.schema?["required"]?.array?.compactMap(\.string) ?? [])
        return props.keys.sorted().map { key in
            let p = props[key]!
            var options: [(String, String)] = []
            if let e = p["enum"]?.array {
                let names = p["enumNames"]?.array?.compactMap(\.string) ?? []
                options = e.enumerated().compactMap { i, v in v.string.map { ($0, i < names.count ? names[i] : $0) } }
            } else if let one = p["oneOf"]?.array ?? p["anyOf"]?.array {
                options = one.compactMap { o in o["const"]?.string.map { ($0, o["title"]?.string ?? $0) } }
            }
            return Field(
                key: key,
                title: p["title"]?.string ?? key.replacingOccurrences(of: "_", with: " ").capitalized,
                help: p["description"]?.string,
                type: p["type"]?.string ?? "string",
                options: options,
                required: required.contains(key),
                fallback: p["default"])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: request.url == nil ? "questionmark.bubble.fill" : "link.circle.fill")
                    .foregroundStyle(.blue)
                Text("\(request.server) needs your input").fontWeight(.semibold)
                Spacer()
            }
            Text(request.message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let url = request.url {
                Text(url)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                form
            }
            HStack(spacing: 8) {
                if let url = request.url {
                    Button {
                        if let u = URL(string: url), ["https", "http"].contains(u.scheme?.lowercased() ?? "") {
                            openURL(u)
                        }
                        conversation.elicit("accept")
                    } label: {
                        Label("Open in Browser", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                } else {
                    Button { conversation.elicit("accept", content: content) } label: {
                        Text("Submit").frame(minWidth: 56)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!complete)
                    .help("Submit (⌘↩)")
                }
                Spacer()
                Button("Decline") { conversation.elicit("decline") }
                    .buttonStyle(.glass)
                Button("Cancel") { conversation.elicit("cancel") }
                    .buttonStyle(.glass)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Cancel the tool call (⌘.)")
            }
        }
        .padding(TurnSpace.Card.padding)
        .glassEffect(.regular.tint(.blue.opacity(0.10)), in: .rect(cornerRadius: TurnSpace.Card.radius))
        .onAppear(perform: fillDefaults)
    }

    private var form: some View {
        Form {
            ForEach(fields) { f in
                Group {
                    if f.type == "boolean" {
                        Toggle(f.title, isOn: flag(f.key))
                    } else if !f.options.isEmpty {
                        Picker(f.title, selection: text(f.key)) {
                            if !f.required { Text("None").tag("") }
                            ForEach(f.options, id: \.value) { Text($0.title).tag($0.value) }
                        }
                    } else {
                        TextField(f.title, text: text(f.key), prompt: Text(f.required ? "Required" : ""))
                    }
                }
                .help(f.help ?? "")
            }
        }
        .formStyle(.columns)
    }

    private func text(_ key: String) -> Binding<String> {
        Binding { values[key] ?? "" } set: { values[key] = $0 }
    }

    private func flag(_ key: String) -> Binding<Bool> {
        Binding { flags[key] ?? false } set: { flags[key] = $0 }
    }

    private func fillDefaults() {
        for f in fields {
            switch f.fallback {
            case .bool(let b)?: flags[f.key] = b
            case .string(let s)?: values[f.key] = s
            case .number(let n)?: values[f.key] = n == n.rounded() ? String(Int64(n)) : String(n)
            default: if !f.options.isEmpty, f.required { values[f.key] = f.options[0].value }
            }
        }
    }

    private var complete: Bool {
        fields.allSatisfy { f in
            guard f.type != "boolean" else { return true }
            let v = values[f.key, default: ""].trimmingCharacters(in: .whitespaces)
            if v.isEmpty { return !f.required }
            if f.type == "number" { return Double(v) != nil }
            if f.type == "integer" { return Int64(v) != nil }
            return true
        }
    }

    private var content: JSONValue {
        var out: [String: JSONValue] = [:]
        for f in fields {
            if f.type == "boolean" {
                out[f.key] = .bool(flags[f.key] ?? false)
                continue
            }
            let v = values[f.key, default: ""].trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { continue }
            switch f.type {
            case "number", "integer": out[f.key] = Double(v).map(JSONValue.number) ?? .string(v)
            default: out[f.key] = .string(v)
            }
        }
        return .object(out)
    }
}

// MARK: - Images

/// Images a tool returned (renders, plots, screenshots). Click one to see it large.
struct ToolImages: View {
    let images: [ToolImage]
    var preview = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                    if let data = img.bytes, let ns = PlatformImage(data: data) {
                        Image(platformImage: ns)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: preview ? 256 : nil)
                            .frame(maxWidth: images.count == 1 ? 560 : 320, maxHeight: 360)
                            .clipShape(.rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                            .accessibilityLabel("Image \(i + 1) of \(images.count)")
                            .accessibilityAddTraits(.isButton)
                            .opensInLightbox(images, at: i)
                            .draggable(Image(platformImage: ns))
                            .contextMenu {
                                Button("Open in Preview") { open(data, mime: img.mime) }
                                Button("Copy Image") {
                                    Clipboard.copy(ns)
                                }
                            }
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func open(_ data: Data, mime: String) {
        let ext = mime.split(separator: "/").last.map(String.init) ?? "png"
        let url = FileManager.default.temporaryDirectory.appending(path: "frog-\(UUID().uuidString.prefix(8)).\(ext)")
        try? data.write(to: url)
        Platform.open(url)
    }
}

// MARK: - MCP Apps

/// A tool result rendered by the server's own UI (an MCP App, SEP-1865), e.g. vcad's 3D viewer.
struct McpAppCard: View {
    let name: String
    let item: ItemState
    let app: AppView
    let conversation: Conversation
    @State private var height: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: ToolIcon.symbol(name)).foregroundStyle(.secondary).frame(width: TurnSpace.Inset.icon)
                Text(ToolIcon.title(name)).fontWeight(.medium).font(.callout)
                if let arg = item.result?.arg, !arg.isEmpty {
                    Text(arg)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            if FileManager.default.fileExists(atPath: app.html) {
                AppWebView(app: app, input: item.result?.input ?? .object([:]), conversation: conversation, height: $height)
                    .frame(height: height)
                    .clipShape(.rect(cornerRadius: TurnSpace.Card.radius))
                    
            } else {
                Text("This app's view is no longer available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let images = item.result?.images, !images.isEmpty {
                ToolImages(images: images)
            }
        }
    }
}

/// Hosts an MCP App in a web view and speaks the MCP Apps protocol with it (JSON-RPC over
/// `postMessage`). The app runs top-level, so its `window.parent` is itself: a script at
/// document start routes its outgoing messages here and delivers replies as `message` events.
struct AppWebView: PlatformViewRepresentable {
    let app: AppView
    let input: JSONValue
    let conversation: Conversation
    @Binding var height: CGFloat

    func makeCoordinator() -> Host { Host(self) }

    func makeWeb(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let bridge = WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(bridge)
        config.userContentController.add(context.coordinator, name: "frog")
        let web = WKWebView(frame: .zero, configuration: config)
        #if os(macOS)
        web.setValue(false, forKey: "drawsBackground")
        #else
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        #endif
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        context.coordinator.web = web
        if let html = try? String(contentsOfFile: app.html, encoding: .utf8) {
            web.loadHTMLString(html, baseURL: URL(string: "https://\(Self.host(app.server)).mcp-app.localhost/"))
        }
        return web
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWeb(context: context) }
    func updateNSView(_ web: WKWebView, context: Context) { context.coordinator.view = self }
    static func dismantleNSView(_ web: WKWebView, coordinator: Host) { dismantle(web) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWeb(context: context) }
    func updateUIView(_ web: WKWebView, context: Context) { context.coordinator.view = self }
    static func dismantleUIView(_ web: WKWebView, coordinator: Host) { dismantle(web) }
    #endif

    private static func dismantle(_ web: WKWebView) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "frog")
    }

    private static func host(_ server: String) -> String {
        let s = server.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(s).isEmpty ? "app" : String(s)
    }

    private static let bridge = """
    (() => {
      const send = (m) => window.webkit.messageHandlers.frog.postMessage(JSON.stringify(m));
      const own = window.postMessage.bind(window);
      window.postMessage = function (m, ...rest) {
        if (m && m.jsonrpc === "2.0") { send(m); return; }
        return own(m, ...rest);
      };
      window.__frogDeliver = (m) =>
        window.dispatchEvent(new MessageEvent("message", { data: m, source: window }));
    })();
    """

    @MainActor
    final class Host: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var view: AppWebView
        weak var web: WKWebView?
        private var loaded = false

        init(_ view: AppWebView) { self.view = view }

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let text = message.body as? String,
                  let data = text.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let sendable = JSONValue(any: msg)
            Task { @MainActor in self.handle(sendable) }
        }

        private func handle(_ msg: JSONValue) {
            let method = msg["method"]?.string ?? ""
            let id = msg["id"]
            let params = msg["params"] ?? .object([:])
            switch method {
            case "ui/initialize":
                reply(id, result: initializeResult(params))
            case "ui/notifications/initialized":
                deliverToolData()
            case "tools/call":
                let tool = params["name"]?.string ?? ""
                let args = params["arguments"] ?? .object([:])
                view.conversation.callAppTool(server: view.app.server, tool: tool, arguments: args) { [weak self] result, error in
                    if let result { self?.reply(id, result: result.any) }
                    else { self?.fail(id, code: -32000, message: error ?? "tool call failed") }
                }
            case "ui/open-link":
                if let s = params["url"]?.string, let url = URL(string: s), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    Platform.open(url)
                    reply(id, result: [:])
                } else {
                    reply(id, result: ["isError": true])
                }
            case "ui/request-display-mode":
                reply(id, result: ["mode": "inline"])
            case "ui/notifications/size-changed":
                if case .number(let h)? = params["height"] {
                    view.height = min(max(CGFloat(h), 160), 720)
                }
            case "ping":
                reply(id, result: [:])
            default:
                // Notifications (logging and the like) need no answer; unknown requests do.
                if id != nil { fail(id, code: -32601, message: "\(method) isn't supported by frog") }
            }
        }

        private func initializeResult(_ params: JSONValue) -> [String: Any] {
            let dark = Platform.isDark
            let width = web?.bounds.width ?? 760
            return [
                "protocolVersion": params["protocolVersion"]?.string ?? "2026-01-26",
                "hostInfo": ["name": "frog", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"],
                "hostCapabilities": ["openLinks": [:], "serverTools": [:], "logging": [:]],
                "hostContext": [
                    "theme": dark ? "dark" : "light",
                    "displayMode": "inline",
                    "availableDisplayModes": ["inline"],
                    "platform": "desktop",
                    "locale": Locale.current.identifier(.bcp47),
                    "containerDimensions": ["width": width, "maxHeight": 720],
                    "toolInfo": ["tool": ["name": view.app.tool, "inputSchema": ["type": "object"]]],
                ] as [String: Any],
            ]
        }

        /// The tool's arguments, then its result: what the app renders.
        private func deliverToolData() {
            guard !loaded else { return }
            loaded = true
            notify("ui/notifications/tool-input", params: ["arguments": view.input.any])
            if let data = FileManager.default.contents(atPath: view.app.result),
               let result = try? JSONSerialization.jsonObject(with: data) {
                notify("ui/notifications/tool-result", params: result)
            }
        }

        private func reply(_ id: JSONValue?, result: Any) {
            guard let id else { return }
            deliver(["jsonrpc": "2.0", "id": id.any, "result": result])
        }

        private func fail(_ id: JSONValue?, code: Int, message: String) {
            guard let id else { return }
            deliver(["jsonrpc": "2.0", "id": id.any, "error": ["code": code, "message": message]])
        }

        private func notify(_ method: String, params: Any) {
            deliver(["jsonrpc": "2.0", "method": method, "params": params])
        }

        private func deliver(_ message: [String: Any]) {
            guard let web,
                  let data = try? JSONSerialization.data(withJSONObject: message),
                  let json = String(data: data, encoding: .utf8) else { return }
            web.evaluateJavaScript("window.__frogDeliver(\(json))")
        }

        // Links open in the browser; the app itself never navigates away.
        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .allow }
            let external = ["https", "http"].contains(url.scheme?.lowercased() ?? "")
                && url.host()?.hasSuffix(".mcp-app.localhost") != true
            let userLink = action.navigationType == .linkActivated || action.navigationType == .formSubmitted
            if userLink || (external && action.targetFrame?.isMainFrame != false) {
                if external { Platform.open(url) }
                return .cancel
            }
            return .allow
        }

        func webView(_ web: WKWebView, createWebViewWith config: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                Platform.open(url)
            }
            return nil
        }
    }
}
