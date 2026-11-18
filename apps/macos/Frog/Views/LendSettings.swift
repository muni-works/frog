import SwiftUI


/// Pair a Mac with this one: a code typed on the other Mac (Settings › Models › This Mac).
struct PairCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var window: MacLender.PairWindow?
    @State private var failure: String?
    @State private var left = 0
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            Text("Pair a Mac").font(.frog(size: 15, weight: .semibold))
            if let window {
                Text("On the other Mac, open Devices, pick \(Host.current().localizedName ?? "this Mac") and type:")
                    .font(.frog(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(spaced(window.code))
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text(left > 0 ? "Expires in \(left) s" : "Expired")
                    .font(.frog(size: 12))
                    .foregroundStyle(left > 0 ? Color.secondary : Color.red)
                VStack(spacing: 2) {
                    Text("Fingerprint").font(.frog(size: 11)).foregroundStyle(.secondary)
                    Text(window.fingerprint)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else {
                ProgressView()
            }
            HStack {
                if window != nil, left == 0 { Button("New code") { Task { await open() } } }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .task { await open() }
        .onReceive(tick) { _ in if left > 0 { left -= 1 } }
    }

    private func open() async {
        do {
            let w = try await MacLender.shared.openPairing()
            window = w
            left = w.expires_in
            failure = nil
        } catch {
            failure = "Couldn't open a pairing window. Is this version of tang-llm new enough?"
        }
    }

    private func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
