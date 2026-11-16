import SwiftUI

/// The inspector's empty state, one view for Changes, Terminal and Preview: an icon in the faint
/// colour, a title and one muted line, centred. Frog draws it from `Tokens` instead of
/// `ContentUnavailableView`, so the Mac and the web's `.term-empty` look the same.
struct InspectorEmpty: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Tokens.textTertiary)
                .padding(.bottom, 4)
            Text(title)
                .font(.frog(size: Tokens.Size.secondary, weight: .medium))
                .foregroundStyle(Tokens.text)
            Text(detail)
                .font(.frog(size: Tokens.Size.status))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The inspector's pill buttons, the web's `.f-btn`: `bordered` is the neutral one (Commit),
/// `prominent` the green one (Open PR, Push), `plain` a quiet text button (Expand all).
struct InspectorButtonStyle: ButtonStyle {
    enum Kind { case bordered, prominent, plain }
    var kind: Kind = .bordered

    func makeBody(configuration: Configuration) -> some View {
        Styled(kind: kind, configuration: configuration)
    }

    private struct Styled: View {
        let kind: Kind
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            Group {
                switch kind {
                case .plain:
                    configuration.label
                        .font(.frog(size: 12))
                        .foregroundStyle(hovering ? Tokens.text : Tokens.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(hovering ? Tokens.hover : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                case .bordered:
                    configuration.label
                        .font(.frog(size: Tokens.Size.secondary, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Tokens.hover, in: .capsule)
                        .background(hovering ? Tokens.hover : .clear, in: .capsule)
                case .prominent:
                    configuration.label
                        .font(.frog(size: Tokens.Size.secondary, weight: .semibold))
                        .foregroundStyle(Tokens.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Tokens.accent, in: .capsule)
                        .brightness(hovering ? 0.04 : 0)
                }
            }
            .contentShape(.capsule)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .onHover { hovering = $0 }
        }
    }
}
