import SwiftUI

/// The context ring; click it for how full the context is and to compact it.
struct ContextButton: View {
    let conversation: Conversation
    let status: Status
    @State private var shown = false

    private var fraction: Double {
        guard let used = status.contextTokens, status.contextWindow > 0 else { return 0 }
        return min(1, Double(used) / Double(status.contextWindow))
    }

    #if os(macOS)
    private static let explainer = "Summarizes the conversation so far to free up room (⇧⌘K)."
    #else
    private static let explainer = "Summarizes the conversation so far to free up room."
    #endif

    var body: some View {
        Button { shown.toggle() } label: {
            ContextRing(status: status).hoverPlate(h: 4, v: 4)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shown, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Context").font(.headline)
                    Spacer()
                    Text("\(Int(fraction * 100))%").font(.headline.monospacedDigit())
                        .foregroundStyle(fraction > 0.8 ? .red : fraction > 0.6 ? .orange : .primary)
                }
                ProgressView(value: fraction)
                    .tint(fraction > 0.8 ? .red : fraction > 0.6 ? .orange : .accentColor)
                Text("\((status.contextTokens ?? 0).tokens) of \(status.contextWindow.tokens) tokens")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Divider()
                Button {
                    shown = false
                    conversation.compact()
                } label: {
                    Label("Compact Now", systemImage: "arrow.down.right.and.arrow.up.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(conversation.busy || conversation.turns.isEmpty)
                Text(Self.explainer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #if os(macOS)
                PlanUsage()
                #endif
            }
            .padding(16)
            .frame(width: 260)
            #if os(iOS)
            .presentationCompactAdaptation(.popover)
            .presentationBackground(Color.windowBackground)
            #endif
        }
        .help("Context: \(Int(fraction * 100))% used")
    }
}
