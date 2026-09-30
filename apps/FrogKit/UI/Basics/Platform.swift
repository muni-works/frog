import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The few places AppKit and UIKit differ in name only, bridged once so shared views read the
/// same on every platform.
#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#elseif os(iOS)
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

extension Image {
    init(platformImage image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

@MainActor
enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }

    static func copy(_ image: PlatformImage) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        #elseif os(iOS)
        UIPasteboard.general.image = image
        #endif
    }
}

extension View {
    /// A soft rounded plate behind a plain control while the pointer is over it, so chromeless
    /// buttons and menus still answer the pointer (and on iPad, the trackpad). The padding is
    /// the plate's margin.
    func hoverPlate(h: CGFloat = 7, v: CGFloat = 3, radius: CGFloat = 7) -> some View {
        modifier(HoverPlate(h: h, v: v, radius: radius))
    }
}

private struct HoverPlate: ViewModifier {
    let h: CGFloat
    let v: CGFloat
    let radius: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, h)
            .padding(.vertical, v)
            .background(Color.primary.opacity(hovering && enabled ? 0.08 : 0), in: .rect(cornerRadius: radius, style: .continuous))
            .contentShape(.rect)
            #if !os(watchOS)
            .onHover { hovering = $0 }
            #endif
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension Color {
    /// The window's own background (behind cards and floating labels).
    static var windowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #elseif os(iOS)
        Color(uiColor: .systemBackground)
        #else
        .black
        #endif
    }
}

extension View {
    /// A button that reads as a link: the Mac's link style, a tinted borderless button elsewhere.
    @ViewBuilder
    func linkButton() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless).tint(.accentColor)
        #endif
    }
}

/// How tight the transcript is: a setting on the Mac, comfortable elsewhere.
enum Density: String, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
