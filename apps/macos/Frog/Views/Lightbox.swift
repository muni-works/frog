import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Click an image anywhere in a conversation (a prompt's attachments, a tool's renders, the
/// composer's pending images) to see it large, in the window: pinch or double-click to zoom,
/// drag to pan, arrows to flip through its siblings, Esc or a click outside to close.
@MainActor
@Observable
final class Lightbox {
    private(set) var images: [ToolImage] = []
    var index = 0
    var isOpen: Bool { !images.isEmpty }

    func show(_ images: [ToolImage], at index: Int) {
        self.images = images
        self.index = min(max(index, 0), images.count - 1)
    }

    func close() { images = [] }

    func step(_ by: Int) {
        guard images.count > 1 else { return }
        index = (index + by + images.count) % images.count
    }
}

extension ToolImage {
    var bytes: Data? { Data(base64Encoded: data) }
    var nsImage: NSImage? { bytes.flatMap(NSImage.init(data:)) }
    var fileExtension: String { UTType(mimeType: mime)?.preferredFilenameExtension ?? "png" }
}

private struct LightboxKey: EnvironmentKey {
    static let defaultValue: Lightbox? = nil
}

extension EnvironmentValues {
    var lightbox: Lightbox? {
        get { self[LightboxKey.self] }
        set { self[LightboxKey.self] = newValue }
    }
}

extension View {
    /// Opens `images` at `index` in the lightbox on click, with a pointer and a hover lift.
    func opensInLightbox(_ images: [ToolImage], at index: Int) -> some View {
        modifier(LightboxThumbnail(images: images, index: index))
    }
}

private struct LightboxThumbnail: ViewModifier {
    let images: [ToolImage]
    let index: Int
    @Environment(\.lightbox) private var lightbox
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.02 : 1)
            .shadow(color: .black.opacity(hovering ? 0.18 : 0), radius: 8, y: 3)
            .animation(.snappy(duration: 0.18), value: hovering)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .pointerStyle(.link)
            .onTapGesture {
                withAnimation(.spring(duration: 0.32, bounce: 0.18)) {
                    lightbox?.show(images, at: index)
                }
            }
    }
}

/// Hosts a lightbox over its content (the transcript and composer).
struct LightboxHost: ViewModifier {
    @State private var lightbox = Lightbox()

    func body(content: Content) -> some View {
        content
            .environment(\.lightbox, lightbox)
            .overlay {
                if lightbox.isOpen {
                    LightboxView(lightbox: lightbox)
                        .ignoresSafeArea()
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.94)),
                            removal: .opacity.combined(with: .scale(scale: 0.97))
                        ))
                }
            }
            // The title bar's controls would float over the image.
            .toolbar(lightbox.isOpen ? .hidden : .automatic, for: .windowToolbar)
    }
}

private struct LightboxView: View {
    let lightbox: Lightbox
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var copied = false
    @FocusState private var focused: Bool

    private var current: ToolImage? { lightbox.images.indices.contains(lightbox.index) ? lightbox.images[lightbox.index] : nil }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.62))
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            if let img = current, let ns = img.nsImage {
                Image(nsImage: ns)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: ns.size.width, maxHeight: ns.size.height)
                    .clipShape(.rect(cornerRadius: scale > 1 ? 0 : 12))
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
                    .scaleEffect(scale)
                    .offset(offset)
                    .padding(.horizontal, 48)
                    .padding(.top, 48)
                    .padding(.bottom, 88)
                    .gesture(magnify)
                    .simultaneousGesture(pan)
                    .onTapGesture(count: 2) { toggleZoom() }
                    .id(lightbox.index)
                    .transition(.opacity)
                    .contextMenu { actions(img, ns) }
            }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .help("Close (Esc)")
                }
                Spacer()
                if let img = current, let ns = img.nsImage {
                    toolbar(img, ns)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(.space) { dismiss(); return .handled }
        .onKeyPress(.leftArrow) { flip(-1); return .handled }
        .onKeyPress(.rightArrow) { flip(1); return .handled }
        .onChange(of: lightbox.index) { resetZoom() }
    }

    private func toolbar(_ img: ToolImage, _ ns: NSImage) -> some View {
        HStack(spacing: 4) {
            if lightbox.images.count > 1 {
                bar("chevron.left", "Previous (←)") { flip(-1) }
                Text("\(lightbox.index + 1) of \(lightbox.images.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                bar("chevron.right", "Next (→)") { flip(1) }
                Divider().frame(height: 18).padding(.horizontal, 4)
            }
            Text("\(Int(ns.size.width)) × \(Int(ns.size.height))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            bar(scale > 1 ? "minus.magnifyingglass" : "plus.magnifyingglass", scale > 1 ? "Fit" : "Zoom") { toggleZoom() }
            bar(copied ? "checkmark" : "doc.on.doc", "Copy") { copy(ns) }
            bar("square.and.arrow.down", "Save…") { save(img) }
            bar("arrow.up.forward.app", "Open in Preview") { openInPreview(img) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    private func bar(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func actions(_ img: ToolImage, _ ns: NSImage) -> some View {
        Button("Copy Image") { copy(ns) }
        Button("Save…") { save(img) }
        Button("Open in Preview") { openInPreview(img) }
    }

    // MARK: Zoom and pan

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { scale = min(max(base * $0.magnification, 1), 8) }
            .onEnded { _ in
                base = scale
                if scale <= 1.01 { withAnimation(.snappy) { resetZoom() } }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { v in
                guard scale > 1 else { return }
                offset = CGSize(width: dragStart.width + v.translation.width, height: dragStart.height + v.translation.height)
            }
            .onEnded { _ in dragStart = offset }
    }

    private func toggleZoom() {
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
            if scale > 1 { resetZoom() } else { scale = 2.5; base = 2.5 }
        }
    }

    private func resetZoom() {
        scale = 1; base = 1; offset = .zero; dragStart = .zero
    }

    private func flip(_ by: Int) {
        withAnimation(.easeInOut(duration: 0.18)) { lightbox.step(by) }
    }

    private func dismiss() {
        withAnimation(.spring(duration: 0.28, bounce: 0.1)) { lightbox.close() }
    }

    // MARK: Actions

    private func copy(_ ns: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([ns])
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation { copied = false }
        }
    }

    private func save(_ img: ToolImage) {
        guard let data = img.bytes else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "image.\(img.fileExtension)"
        if let type = UTType(mimeType: img.mime) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private func openInPreview(_ img: ToolImage) {
        guard let data = img.bytes else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "frog-\(UUID().uuidString.prefix(8)).\(img.fileExtension)")
        try? data.write(to: url)
        NSWorkspace.shared.open(url)
    }
}
