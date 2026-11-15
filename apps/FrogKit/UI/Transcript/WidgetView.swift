import SwiftUI
import WebKit

/// A visual the model made with `Visualize` (widget.rs): the engine's sandboxed document in a
/// web view with no website data, no navigation, no popups and no network but the CSP's pinned
/// CDNs. The shell reports its height and may ask a follow-up (`sendPrompt`), which only a
/// click can trigger and which is rate-limited here; the ask shows up as your message.
struct WidgetCard: View {
    let widget: VisualWidget
    let conversation: Conversation
    @State private var height: CGFloat = 320
    @State private var showSource = false
    @State private var expanded = false
    @State private var asked: String?
    @State private var gate = PromptGate()
    @State private var ready = false
    @State private var fullReady = false

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
            WidgetWebView(html: widget.html, height: .constant(0), onPrompt: ask, inline: false, onReady: { fullReady = true })
                .overlay { if !fullReady { cover } }
                .onDisappear { fullReady = false }
        } else {
            WidgetWebView(html: widget.html, height: $height, onPrompt: ask, onReady: { ready = true })
                .frame(height: height)
                .overlay { if !ready { cover } }
                .animation(.easeOut(duration: 0.2), value: ready)
        }
    }

    /// Over the web view until the widget's first layout. A cover, not opacity: WebKit stops
    /// painting a web view that starts transparent and doesn't resume when it's shown.
    private var cover: some View {
        Rectangle().fill(.background).overlay { drawing }
    }

    /// A quiet line, not a blank box.
    private var drawing: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Drawing…").font(.callout).foregroundStyle(.secondary)
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

extension VisualWidget {
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
    /// Inline cards are sized to their content, so wheel scrolling belongs to the transcript.
    var inline = true
    /// The widget laid out (its first height report): time to show it.
    var onReady: () -> Void = {}

    func makeCoordinator() -> Host { Host(self) }

    func makeWeb(context: Context) -> WKWebView { Self.makeWebView(html: html, host: context.coordinator, inline: inline) }

    /// The locked-down web view, loaded with `html` and reporting to `host`.
    static func makeWebView(html: String, host: Host, inline: Bool = true) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Nothing persists and nothing is shared with the app's other web views.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakHandler(host), name: "frog")
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.dataDetectorTypes = []
        #endif
        #if os(macOS)
        let web = WidgetWKWebView(frame: .zero, configuration: config)
        web.passesScroll = inline
        #else
        let web = WKWebView(frame: .zero, configuration: config)
        #endif
        #if os(macOS)
        web.setValue(false, forKey: "drawsBackground")
        #else
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        #endif
        web.navigationDelegate = host
        web.uiDelegate = host
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
                case "ready":
                    self.view.onReady()
                case "height":
                    self.view.onReady()
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

#if os(macOS)
/// A widget's web view. Inline it hands wheel events to the transcript, so scrolling past a
/// visual never gets stuck on it; expanded it scrolls itself.
final class WidgetWKWebView: WKWebView {
    var passesScroll = true
    override func scrollWheel(with event: NSEvent) {
        if passesScroll { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}
#endif
