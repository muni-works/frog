import SwiftUI

/// The window controls (docs/design/chrome/spec.md, "The top-right controls"): one capsule at the
/// conversation area's top right, Split, Commands, Inspector. Frog draws it, not the toolbar's
/// glass, so the web's `ui/WindowControls.tsx` can be the same control and both can be measured
/// (`docs/design/chrome/parity`). Labels stay Split / Commands / Inspector (flow tests press them).
struct WindowControls: View {
    var canSplit: Bool
    var paletteOn: Bool
    var inspectorOn: Bool
    var inspectorEnabled: Bool
    let split: () -> Void
    let splitRight: () -> Void
    let splitDown: () -> Void
    let palette: () -> Void
    let inspector: () -> Void

    static let height: CGFloat = 34
    static let padding: CGFloat = 3

    var body: some View {
        HStack(spacing: 0) {
            ChromeButton(label: "Split", symbol: "rectangle.split.2x1", tip: "Split pane (⌘\\)", action: split)
                .contextMenu {
                    Button("Split Right", action: splitRight)
                    Button("Split Down", action: splitDown)
                }
                .disabled(!canSplit)
            ChromeButton(label: "Commands", symbol: "command", tip: "Command palette (⌘K)", on: paletteOn, action: palette)
            ChromeButton(label: "Inspector", symbol: "sidebar.right", tip: "Inspector (⌥⌘0)", on: inspectorOn, action: inspector)
                .disabled(!inspectorEnabled)
        }
        .padding(Self.padding)
        .frame(height: Self.height)
        .background(Tokens.raised, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Window controls")
    }
}

/// One of the window controls: a 34 × 28 capsule with a 16 pt symbol, the spec's states (rest,
/// hover, pressed, on, disabled).
struct ChromeButton: View {
    let label: String
    let symbol: String
    let tip: String
    var on: Bool? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 34, height: 28)
                .contentShape(.capsule)
        }
        .buttonStyle(ChromeButtonStyle(on: on ?? false, hovering: hovering && enabled))
        .onHover { hovering = $0 }
        .help(tip)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on == true ? .isSelected : [])
    }
}

private struct ChromeButtonStyle: ButtonStyle {
    let on: Bool
    let hovering: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let lit = on || configuration.isPressed
        configuration.label
            .foregroundStyle(lit || hovering ? Tokens.text : Tokens.textSecondary)
            .background(lit ? Tokens.well : (hovering ? Tokens.hover : .clear), in: .capsule)
            .opacity(enabled ? 1 : 0.35)
    }
}
