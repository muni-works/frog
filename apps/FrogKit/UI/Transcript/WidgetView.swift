import SwiftUI
import WebKit

/// A visual the model made with `Visualize` (widget.rs): the engine's sandboxed document in a
/// web view with no website data, no navigation, no popups and no network but the CSP's pinned
/// CDNs. The shell reports its height and may ask a follow-up (`sendPrompt`), which only a
/// click can trigger and which is rate-limited here; the ask shows up as your message.
struct WidgetCard: View {
    let widget: Widget
    let conversation: Conversation
    @State private var height: CGFloat = 320
    @State private var showSource = false
    @State private var expanded = false
    @State private var asked: String?
    @State private var gate = PromptGate()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(expand: true)
            Divider().opacity(0.5)
            content(fill: false)
            if let asked {
                Divider().opacity(0.5)
                Text("Asked Frog: “\(asked)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: TurnSpace.Card.radius))
        .clipShape(.rect(cornerRadius: TurnSpace.Card.radius))
        .sheet(isPresented: $expanded) {
            VStack(spacing: 0) {
                HStack {
                    Text(widget.displayTitle).font(.callout.weight(.semibold))
                    Spacer()
                    sourceButton
                    Button("Done") { expanded = false }.keyboardShortcut(.cancelAction)
                }
                .padding(12)
                Divider().opacity(0.5)
                content(fill: true)
            }
            #if os(macOS)
            .frame(minWidth: 900, idealWidth: 1100, minHeight: 640, idealHeight: 820)
            #endif
        }
    }

    @ViewBuilder
    private func content(fill: Bool) -> some View {
        if showSource {
            ScrollView([.horizontal, .vertical]) {
                Text(widget.code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: fill ? .infinity : 480)
        } else if fill {
            WidgetWebView(html: widget.html, height: .constant(0), onPrompt: ask)
        } else {
            WidgetWebView(html: widget.html, height: $height, onPrompt: ask)
                .frame(height: height)
        }
    }

    private func header(expand: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ToolIcon.symbol("Visualize")).foregroundStyle(.secondary)
            Text("Made a visual").font(.callout).foregroundStyle(.secondary)
            Text(widget.displayTitle).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
            Spacer()
            sourceButton
            Button {
                expanded = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Expand")
            .accessibilityLabel("Expand")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sourceButton: some View {
        Button(showSource ? "Visual" : "Source") { withAnimation(.snappy) { showSource.toggle() } }
            .buttonStyle(.borderless)
            .font(.caption)
    }

    private func ask(_ text: String) {
        guard gate.allow(Date()) else { return }
        asked = text
        conversation.submit(text)
    }
}

/// At most one follow-up every `gap` seconds and `max` per minute, per widget.
struct PromptGate {
    var gap: TimeInterval = 4
    var max = 3
    var window: TimeInterval = 60
    private var at: [Date] = []

    mutating func allow(_ now: Date) -> Bool {
        at.removeAll { now.timeIntervalSince($0) > window }
        if at.count >= max { return false }
        if let last = at.last, now.timeIntervalSince(last) < gap { return false }
        at.append(now)
        return true
    }
}

extension Widget {
    /// `casimir_plate_modes` → "Casimir plate modes"; titles already in words stay as they are.
    var displayTitle: String {
        guard !title.contains(" "), title.contains(where: { $0 == "_" || $0 == "-" }) else {
            return title.isEmpty ? "Visual" : title
        }
        let s = title.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

struct WidgetWebView: PlatformViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    let onPrompt: (String) -> Void

    func makeCoordinator() -> Host { Host(self) }

    func makeWeb(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Nothing persists and nothing is shared with the app's other web views.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakHandler(context.coordinator), name: "frog")
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.dataDetectorTypes = []
        #endif
        let web = WKWebView(frame: .zero, configuration: config)
        #if os(macOS)
        web.setValue(false, forKey: "drawsBackground")
        #else
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        #endif
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.loadHTMLString(html, baseURL: nil)
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

    /// The script handler holds the host weakly: WebKit retains its handlers.
    final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: (any WKScriptMessageHandler)?
        init(_ target: any WKScriptMessageHandler) { self.target = target }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            target?.userContentController(c, didReceive: m)
        }
    }

    @MainActor
    final class Host: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var view: WidgetWebView
        private var loaded = false

        init(_ view: WidgetWebView) { self.view = view }

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let text = message.body as? String,
                  let data = text.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  msg["frogWidget"] as? Int == 1 else { return }
            let type = msg["type"] as? String ?? ""
            let height = (msg["height"] as? NSNumber)?.doubleValue
            let prompt = msg["text"] as? String
            Task { @MainActor in
                switch type {
                case "height":
                    if let height { self.view.height = min(max(CGFloat(height.rounded(.up)), 120), 1400) }
                case "prompt":
                    if let prompt, !prompt.isEmpty { self.view.onPrompt(String(prompt.prefix(2000))) }
                default: break
                }
            }
        }

        // The document is loaded once from a string; it never navigates anywhere after.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if !loaded, action.request.url?.absoluteString == "about:blank" || action.request.url == nil {
                decisionHandler(.allow)
                return
            }
            if action.targetFrame?.isMainFrame == false, action.request.url?.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}
