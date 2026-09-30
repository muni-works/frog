import AppKit
import SwiftUI
import WebKit

/// A live preview of what the agent builds: a web view with an address bar, a device-width
/// picker, an inspect mode that turns a clicked element into an `@mention`, and a then/now
/// switch when the timeline has a screenshot for the selected turn. The engine reads and drives
/// the page through `paneRequest`s, and hears what the page logs through `paneReport`s.
struct PreviewPane: View {
    let pane: ToolPane
    let hub: PaneHub
    /// Shown instead of a URL (fixtures and snapshots).
    var html: String? = nil
    @State private var address = ""
    @State private var device = Device.desktop
    @State private var showThen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var host: PreviewHost { hub.previewHost(pane.id) }

    enum Device: String, CaseIterable, Identifiable {
        case phone, tablet, desktop
        var id: String { rawValue }
        var width: CGFloat? {
            switch self {
            case .phone: 390
            case .tablet: 820
            case .desktop: nil
            }
        }
        var symbol: String {
            switch self {
            case .phone: "iphone"
            case .tablet: "ipad"
            case .desktop: "desktopcomputer"
            }
        }
    }

    private var checkpoint: Checkpoint? {
        hub.comparing.flatMap { hub.checkpoints[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if checkpoint != nil { thenNow }
            content
                .padding([.horizontal, .bottom], 10)
        }
        .onAppear {
            address = host.currentURL ?? pane.url ?? ""
            if let html { host.load(html: html) } else if let url = pane.url, host.currentURL == nil { host.load(url) }
        }
        .onChange(of: pane.url) { _, url in
            // The engine (or a reopened pane) asked for a page.
            guard let url, url != host.currentURL else { return }
            address = url
            host.load(url)
        }
        .onChange(of: host.currentURL) { _, url in if let url { address = url } }
        .onChange(of: hub.inspecting) { _, on in host.setInspecting(on) }
        .onChange(of: hub.comparing) { showThen = hub.comparing != nil }
        .animation(Motion.quick(reduced: reduceMotion), value: checkpoint != nil)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { host.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!host.canGoBack)
                .help("Back")
            Button { host.reload() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(host.currentURL == nil)
                .help("Reload")
            HStack(spacing: 5) {
                if host.loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "globe").foregroundStyle(.tertiary)
                }
                TextField("URL or port", text: $address)
                    .textFieldStyle(.plain)
                    .onSubmit { go() }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
            Picker("Device", selection: $device) {
                ForEach(Device.allCases) { d in Image(systemName: d.symbol).tag(d) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Device width")
            Button {
                hub.inspecting.toggle()
            } label: {
                Image(systemName: "cursorarrow.click.2")
                    .foregroundStyle(hub.inspecting ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .help("Inspect: click an element to mention it (⇧⌘I)")
            if let m = hub.mention, hub.mentionInDraft {
                Text(m)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.18), in: .capsule)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Button {
                if let u = host.currentURL.flatMap(URL.init) { NSWorkspace.shared.open(u) }
            } label: { Image(systemName: "safari") }
                .disabled(host.currentURL == nil)
                .help("Open in Browser")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Before (the turn's checkpoint) or after (the live page).
    private var thenNow: some View {
        HStack(spacing: 8) {
            Picker("", selection: $showThen) {
                Text("Then").tag(true)
                Text("Now").tag(false)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if let turn = hub.comparing {
                Text("Turn \(turn)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { hub.comparing = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop comparing")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        GeometryReader { geo in
            let width = min(geo.size.width, device.width ?? geo.size.width)
            ZStack {
                PreviewWebView(host: host)
                    .opacity(pane.url == nil && host.currentURL == nil ? 0 : 1)
                if pane.url == nil, host.currentURL == nil {
                    hint
                }
                if showThen, let checkpoint {
                    Image(nsImage: checkpoint.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(Color(nsColor: .textBackgroundColor))
                }
                if hub.inspecting {
                    Text("Click an element to mention it · Esc to stop")
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: geo.size.height)
            .clipShape(.rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
            .frame(maxWidth: .infinity)
            .animation(Motion.quick(reduced: reduceMotion), value: width)
        }
        .background(Color.black.opacity(0.18), in: .rect(cornerRadius: 10))
        .onExitCommand { hub.inspecting = false }
    }

    private var hint: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe").font(.title).foregroundStyle(.tertiary)
            Text("Run your dev server, then enter its URL, or ask frog to open it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .padding()
    }

    /// Go to what's in the address field: a URL, a host without a scheme, or just a port.
    private func go() {
        let raw = address.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let url: String
        if raw.allSatisfy(\.isNumber) { url = "http://localhost:\(raw)" }
        else if raw.contains("://") { url = raw }
        else if raw.hasPrefix(":") { url = "http://localhost\(raw)" }
        else { url = "http://\(raw)" }
        address = url
        host.load(url)
    }
}

/// The web view and its bridge: the injected script reports what the page does, and the engine's
/// requests are answered here. Owned by the pane view, so it outlives layout changes.
@MainActor
@Observable
final class PreviewHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var hub: PaneHub?
    var paneID = "" {
        didSet {
            if oldValue != paneID { hub?.unregister(oldValue) }
            hub?.register(paneID) { [weak self] req, reply in self?.handle(req, reply) }
        }
    }
    private(set) var currentURL: String?
    private(set) var title = ""
    private(set) var loading = false
    /// Why the last load failed, until the next one starts.
    private var loadError: String?
    private(set) var canGoBack = false
    @ObservationIgnored private(set) var web: WKWebView?
    @ObservationIgnored private var inspecting = false
    /// Waiting for a navigation the engine asked for to finish.
    @ObservationIgnored private var navigationWaiter: ((JSONValue?, String?) -> Void)?

    override init() {
        super.init()
    }

    func makeWebView() -> WKWebView {
        if let web { return web }
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(self, name: "frogPreview")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isInspectable = true
        web.allowsBackForwardNavigationGestures = true
        self.web = web
        return web
    }

    func load(_ string: String) {
        guard let url = URL(string: string) ?? URL(string: string.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""),
              url.scheme != nil else { return }
        // A page on disk can read its folder (stylesheets, images, sibling pages).
        if url.isFileURL {
            makeWebView().loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }
        makeWebView().load(URLRequest(url: url))
    }

    /// Show a page from a string, as if it were at `about:preview`.
    func load(html: String) {
        makeWebView().loadHTMLString(html, baseURL: nil)
        currentURL = "about:preview"
    }

    func reload() { web?.reload() }
    func goBack() { web?.goBack() }

    func setInspecting(_ on: Bool) {
        inspecting = on
        web?.evaluateJavaScript("window.__frogPreview && window.__frogPreview.inspect(\(on))")
    }

    // MARK: Reports from the page

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String, let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let msg = JSONValue(any: obj)
        Task { @MainActor in self.received(msg) }
    }

    private func received(_ m: JSONValue) {
        guard let hub else { return }
        let text = m["message"]?.string ?? ""
        switch m["type"]?.string {
        case "console":
            let level = m["level"]?.string ?? "info"
            var line = text
            if let src = m["source"]?.string, !src.isEmpty { line += "  (\(src))" }
            hub.report(PaneReport(id: paneID, kind: .console, level: level, message: line))
        case "error":
            hub.report(PaneReport(id: paneID, kind: .error, level: "error", message: text, url: m["url"]?.string))
        case "network":
            let status = m["status"].flatMap { if case .number(let n) = $0 { Int(n) } else { nil } }
            hub.report(PaneReport(id: paneID, kind: .network, level: "error", message: text, url: m["url"]?.string, status: status))
        case "title":
            title = text
            hub.retitle(paneID, text)
            hub.report(PaneReport(id: paneID, kind: .title, message: text, url: currentURL))
        case "mention":
            hub.mention(paneID, token: m["token"]?.string ?? "@element", context: m["context"]?.string)
        default:
            break
        }
    }

    // MARK: Requests from the engine

    private func handle(_ req: PaneRequest, _ reply: @escaping (JSONValue?, String?) -> Void) {
        guard let web else { return reply(nil, "the preview hasn't loaded a page") }
        switch req.action {
        case "read":
            web.evaluateJavaScript("window.__frogPreview.read()") { r, e in
                reply((r as? String).map(JSONValue.string), e?.localizedDescription)
            }
        case "click":
            guard let sel = req.args["selector"]?.string else { return reply(nil, "click needs a selector") }
            web.evaluateJavaScript("window.__frogPreview.click(\(Self.js(sel)))") { r, e in
                reply(Self.value(r), e?.localizedDescription)
            }
        case "type":
            guard let sel = req.args["selector"]?.string else { return reply(nil, "type needs a selector") }
            let text = req.args["text"]?.string ?? ""
            web.evaluateJavaScript("window.__frogPreview.type(\(Self.js(sel)), \(Self.js(text)))") { r, e in
                reply(Self.value(r), e?.localizedDescription)
            }
        case "navigate":
            guard let url = req.args["url"]?.string else { return reply(nil, "navigate needs a url") }
            // `wait`: the pane was just opened at this URL; answer when that load settles
            // rather than loading it again.
            if req.args["wait"]?.bool == true {
                if let loadError { return reply(nil, loadError) }
                if !loading, currentURL != nil {
                    return reply(.object(["url": .string(currentURL ?? url), "title": .string(title), "loaded": .bool(true)]), nil)
                }
            }
            navigationWaiter?(nil, "superseded by another navigation")
            navigationWaiter = reply
            if req.args["wait"]?.bool != true { load(url) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, let w = self.navigationWaiter else { return }
                self.navigationWaiter = nil
                w(.object(["url": .string(self.currentURL ?? url), "title": .string(self.title), "loaded": .bool(false)]), nil)
            }
        case "eval":
            guard let js = req.args["js"]?.string else { return reply(nil, "eval needs js") }
            web.callAsyncJavaScript("return (0, eval)(__js)", arguments: ["__js": js], in: nil, in: .page) { result in
                switch result {
                case .success(let v): reply(Self.value(v) ?? .null, nil)
                case .failure(let e): reply(nil, e.localizedDescription)
                }
            }
        case "screenshot":
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = true
            web.takeSnapshot(with: config) { [weak self] image, error in
                guard let image, let png = image.png else { return reply(nil, error?.localizedDescription ?? "no snapshot") }
                if req.args["for"]?.string == "checkpoint", let hub = self?.hub {
                    let turn = req.args["turn"].flatMap { if case .number(let n) = $0 { UInt64(n) } else { nil } } ?? hub.currentTurn ?? 0
                    hub.checkpoint(image, turn: turn)
                }
                reply(.object([
                    "mime": .string("image/png"),
                    "data": .string(png.base64EncodedString()),
                    "width": .number(Double(image.size.width)),
                    "height": .number(Double(image.size.height)),
                ]), nil)
            }
        default:
            reply(nil, "unknown pane action \(req.action)")
        }
    }

    private static func js(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    private static func value(_ any: Any?) -> JSONValue? {
        guard let any else { return nil }
        return JSONValue(any: any)
    }

    // MARK: Navigation

    func webView(_ web: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        loadError = nil
    }

    func webView(_ web: WKWebView, didCommit navigation: WKNavigation!) {
        noteURL(web)
    }

    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        noteURL(web)
        title = web.title ?? ""
        hub?.retitle(paneID, title)
        if inspecting { setInspecting(true) }
        if let w = navigationWaiter {
            navigationWaiter = nil
            w(.object(["url": .string(currentURL ?? ""), "title": .string(title), "loaded": .bool(true)]), nil)
        }
    }

    func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        loading = false
        // A navigation the user cancelled by starting another isn't news.
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loadError = error.localizedDescription
        hub?.report(PaneReport(id: paneID, kind: .error, level: "error", message: "Couldn't load: \(error.localizedDescription)", url: currentURL))
        if let w = navigationWaiter {
            navigationWaiter = nil
            w(nil, error.localizedDescription)
        }
    }

    private func noteURL(_ web: WKWebView) {
        canGoBack = web.canGoBack
        let url = web.url?.absoluteString
        guard url != currentURL else { return }
        currentURL = url
        hub?.navigated(paneID, to: url)
        if let url { hub?.report(PaneReport(id: paneID, kind: .navigated, message: url, url: url)) }
    }

    func webView(_ web: WKWebView, createWebViewWith config: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank links stay in the preview.
        if let url = action.request.url { web.load(URLRequest(url: url)) }
        return nil
    }

    // MARK: The injected script

    /// Runs at document start in the main frame. Forwards console output, errors, failed
    /// requests and title changes; answers read/click/type; and does inspect mode's highlight
    /// and mention on click.
    static let script = #"""
    (() => {
      if (window.__frogPreview) return;
      const post = (m) => { try { window.webkit.messageHandlers.frogPreview.postMessage(JSON.stringify(m)); } catch (e) {} };
      const fmt = (a) => {
        if (typeof a === "string") return a;
        if (a instanceof Error) return a.stack || a.message;
        try { return JSON.stringify(a); } catch (e) { return String(a); }
      };
      const where = () => {
        try {
          const lines = (new Error().stack || "").split("\n").filter(l => !/__frog|console\.|<anonymous>$/.test(l));
          const m = lines[1] && lines[1].match(/(https?:\/\/[^\s)]+|file:[^\s)]+)/);
          if (!m) return "";
          return m[1].replace(location.origin, "");
        } catch (e) { return ""; }
      };
      // Console.
      for (const level of ["log", "info", "warn", "error", "debug"]) {
        const orig = console[level];
        console[level] = function (...args) {
          post({ type: "console", level: level === "warn" ? "warn" : level === "error" ? "error" : "info", message: args.map(fmt).join(" "), source: where() });
          return orig.apply(this, args);
        };
      }
      // Errors.
      window.addEventListener("error", (e) => {
        const src = e.filename ? `${(e.filename || "").replace(location.origin, "")}:${e.lineno}:${e.colno}` : "";
        post({ type: "error", message: (e.message || String(e.error)) + (src ? `  (${src})` : ""), url: location.href });
      });
      window.addEventListener("unhandledrejection", (e) => {
        post({ type: "error", message: "Unhandled promise rejection: " + fmt(e.reason), url: location.href });
      });
      // Failed requests.
      const ofetch = window.fetch;
      if (ofetch) {
        window.fetch = function (input, init) {
          const url = typeof input === "string" ? input : (input && input.url) || String(input);
          return ofetch.apply(this, arguments).then((r) => {
            if (r.status >= 400) post({ type: "network", message: `${(init && init.method) || "GET"} ${url} → ${r.status}`, url, status: r.status });
            return r;
          }, (err) => {
            post({ type: "network", message: `${(init && init.method) || "GET"} ${url} failed: ${err && err.message}`, url, status: null });
            throw err;
          });
        };
      }
      const oopen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__frogURL = String(url); this.__frogMethod = method;
        this.addEventListener("loadend", () => {
          if (this.status >= 400 || this.status === 0) {
            post({ type: "network", message: `${method} ${url} → ${this.status || "network error"}`, url: String(url), status: this.status || null });
          }
        });
        return oopen.apply(this, arguments);
      };
      // Title.
      let lastTitle = "";
      const watchTitle = () => {
        const t = document.querySelector("title");
        const tell = () => { if (document.title !== lastTitle) { lastTitle = document.title; post({ type: "title", message: document.title }); } };
        tell();
        if (t) new MutationObserver(tell).observe(t, { childList: true, characterData: true, subtree: true });
      };
      if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", watchTitle); else watchTitle();

      // Selectors and names.
      const esc = (s) => (window.CSS && CSS.escape) ? CSS.escape(s) : s.replace(/[^\w-]/g, "\\$&");
      const unique = (sel) => { try { return document.querySelectorAll(sel).length === 1; } catch (e) { return false; } };
      const selector = (el) => {
        if (el.id && unique("#" + esc(el.id))) return "#" + esc(el.id);
        const tag = el.tagName.toLowerCase();
        for (const attr of ["name", "data-testid", "aria-label"]) {
          const v = el.getAttribute(attr);
          if (v) { const s = `${tag}[${attr}="${v.replace(/"/g, '\\"')}"]`; if (unique(s)) return s; }
        }
        const parts = [];
        let node = el;
        while (node && node.nodeType === 1 && node !== document.body && parts.length < 5) {
          let part = node.tagName.toLowerCase();
          if (node.id) { parts.unshift("#" + esc(node.id)); break; }
          const sibs = Array.from(node.parentNode ? node.parentNode.children : []).filter(c => c.tagName === node.tagName);
          if (sibs.length > 1) part += `:nth-of-type(${sibs.indexOf(node) + 1})`;
          parts.unshift(part);
          node = node.parentNode;
        }
        return parts.join(" > ");
      };
      const text = (el) => (el.innerText || el.textContent || "").replace(/\s+/g, " ").trim();
      const label = (el) => {
        if (el.labels && el.labels.length) return text(el.labels[0]);
        return el.getAttribute("aria-label") || el.getAttribute("placeholder") || el.getAttribute("title") || "";
      };
      const role = (el) => {
        const r = el.getAttribute("role"); if (r) return r;
        const tag = el.tagName.toLowerCase();
        return ({ a: "link", button: "button", input: el.type === "submit" || el.type === "button" ? "button" : "input", select: "select", textarea: "input",
                  h1: "heading", h2: "heading", h3: "heading", h4: "heading", nav: "nav", main: "main", header: "header", footer: "footer", form: "form", img: "image" })[tag] || tag;
      };
      const visible = (el) => {
        const r = el.getBoundingClientRect();
        if (!r.width && !r.height) return false;
        const s = getComputedStyle(el);
        return s.visibility !== "hidden" && s.display !== "none";
      };
      const source = (el) => {
        const ds = el.getAttribute("data-source") || el.getAttribute("data-inspector-relative-path");
        if (ds) return ds;
        for (const k of Object.keys(el)) {
          if (k.startsWith("__reactFiber$")) {
            let f = el[k];
            while (f) { if (f._debugSource) return `${f._debugSource.fileName}:${f._debugSource.lineNumber}`; f = f.return; }
          }
        }
        const vc = el.__vueParentComponent;
        if (vc && vc.type && vc.type.__file) return vc.type.__file;
        return "";
      };

      // Read: an outline the model can act on.
      const read = () => {
        const out = [`Title: ${document.title}`, `URL: ${location.href}`, ""];
        const seen = new Set();
        const walk = (node, depth) => {
          if (out.join("\n").length > 4000) return;
          for (const el of node.children) {
            if (!visible(el) || seen.has(el)) continue;
            const tag = el.tagName.toLowerCase();
            const r = role(el);
            const pad = "  ".repeat(Math.min(depth, 6));
            const t = text(el).slice(0, 120);
            if (["script", "style", "noscript", "svg", "path"].includes(tag)) continue;
            if (["nav", "main", "header", "footer", "form", "aside", "section", "article", "dialog"].includes(tag) || el.getAttribute("role")) {
              out.push(`${pad}[${r}]${el.id ? " #" + el.id : ""}${label(el) ? " " + JSON.stringify(label(el)) : ""}`);
              seen.add(el); walk(el, depth + 1); continue;
            }
            if (/^h[1-6]$/.test(tag)) { out.push(`${pad}${tag}: ${t}  {${selector(el)}}`); seen.add(el); continue; }
            if (tag === "a") { out.push(`${pad}link "${t}" → ${el.getAttribute("href") || ""}  {${selector(el)}}`); seen.add(el); continue; }
            if (tag === "button" || (tag === "input" && ["submit", "button"].includes(el.type))) {
              out.push(`${pad}button "${t || el.value || label(el)}"${el.disabled ? " (disabled)" : ""}  {${selector(el)}}`); seen.add(el); continue;
            }
            if (tag === "input" || tag === "textarea" || tag === "select") {
              const v = tag === "select" ? (el.selectedOptions[0] ? el.selectedOptions[0].text : "") : el.type === "password" ? "•••" : el.value;
              out.push(`${pad}${tag === "select" ? "select" : "input"}${el.type ? "[" + el.type + "]" : ""} "${label(el) || el.name || ""}" = ${JSON.stringify(v || "")}  {${selector(el)}}`);
              seen.add(el); continue;
            }
            if (tag === "img") { out.push(`${pad}image "${el.alt || ""}"`); continue; }
            if (el.children.length === 0 || ["p", "li", "td", "th", "label", "span", "pre", "code", "blockquote"].includes(tag)) {
              if (t) out.push(`${pad}${t}`);
              continue;
            }
            walk(el, depth);
          }
        };
        walk(document.body, 0);
        let s = out.join("\n");
        if (s.length > 4000) s = s.slice(0, 4000) + "\n…";
        return s;
      };
      const find = (sel) => {
        const el = document.querySelector(sel);
        if (!el) throw new Error(`no element matches ${sel}`);
        return el;
      };
      const click = (sel) => {
        const el = find(sel);
        el.scrollIntoView({ block: "center" });
        el.focus && el.focus();
        el.click();
        return { ok: true, selector: sel, text: text(el).slice(0, 80) };
      };
      const type = (sel, value) => {
        const el = find(sel);
        el.focus && el.focus();
        const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, "value");
        if (setter && setter.set && ("value" in el)) setter.set.call(el, value); else if (el.isContentEditable) el.textContent = value; else el.value = value;
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return { ok: true, selector: sel, value };
      };

      // Inspect mode: highlight under the pointer, mention on click.
      let overlay = null, hovered = null, on = false;
      const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").split("-").slice(0, 2).join("-");
      const token = (el) => {
        const tag = el.tagName.toLowerCase();
        if (el.id) return "@#" + el.id;
        const name = el.getAttribute("name") || el.getAttribute("data-testid");
        if (name) return `@${tag}.${slug(name)}`;
        if (/^h[1-6]$/.test(tag)) return "@" + tag;
        const t = slug(text(el) || label(el) || el.getAttribute("aria-label") || "");
        const base = t ? `@${role(el)}.${t}` : `@${tag}`;
        const same = Array.from(document.querySelectorAll(tag)).filter(e => slug(text(e) || label(e) || "") === t);
        return same.length > 1 ? `${base}-${same.indexOf(el) + 1}` : base;
      };
      const move = (e) => {
        const el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el || el === overlay || el === hovered) return;
        hovered = el;
        const r = el.getBoundingClientRect();
        overlay.style.left = (r.left + window.scrollX) + "px"; overlay.style.top = (r.top + window.scrollY) + "px";
        overlay.style.width = r.width + "px"; overlay.style.height = r.height + "px";
        overlay.firstChild.textContent = token(el);
      };
      const pick = (e) => {
        e.preventDefault(); e.stopPropagation();
        const el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el || el === overlay) return;
        const r = el.getBoundingClientRect();
        const src = source(el);
        const ctx = [
          `tag: ${el.tagName.toLowerCase()}`, `role: ${role(el)}`,
          text(el) ? `text: ${JSON.stringify(text(el).slice(0, 160))}` : null,
          label(el) ? `label: ${JSON.stringify(label(el))}` : null,
          `selector: ${selector(el)}`,
          `box: ${Math.round(r.left)},${Math.round(r.top)} ${Math.round(r.width)}×${Math.round(r.height)}`,
          src ? `source: ${src}` : null,
          `page: ${location.href}`,
        ].filter(Boolean).join("\n");
        post({ type: "mention", token: token(el), context: ctx });
        inspect(false);
      };
      const inspect = (enable) => {
        if (enable === on) return;
        on = enable;
        if (enable) {
          overlay = document.createElement("div");
          overlay.style.cssText = "position:absolute;pointer-events:none;z-index:2147483647;border:2px solid #34c759;background:rgba(52,199,89,0.15);border-radius:3px;box-sizing:border-box;";
          const tip = document.createElement("span");
          tip.style.cssText = "position:absolute;left:0;top:-20px;background:#34c759;color:#fff;font:11px -apple-system,system-ui,sans-serif;padding:1px 6px;border-radius:3px;white-space:nowrap;";
          overlay.appendChild(tip);
          document.documentElement.appendChild(overlay);
          document.addEventListener("mousemove", move, true);
          document.addEventListener("click", pick, true);
          document.documentElement.style.cursor = "crosshair";
        } else {
          document.removeEventListener("mousemove", move, true);
          document.removeEventListener("click", pick, true);
          if (overlay) overlay.remove();
          overlay = null; hovered = null;
          document.documentElement.style.cursor = "";
        }
      };
      window.__frogPreview = { read, click, type, inspect };
    })();
    """#
}

/// Hosts the pane's one `WKWebView` (kept on the `PreviewHost`) in SwiftUI.
struct PreviewWebView: NSViewRepresentable {
    let host: PreviewHost

    func makeNSView(context: Context) -> WKWebView { host.makeWebView() }
    func updateNSView(_ web: WKWebView, context: Context) {}
}

extension NSImage {
    var png: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
