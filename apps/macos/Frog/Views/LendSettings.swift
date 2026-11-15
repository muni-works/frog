import SwiftUI

/// Settings › Lend: let your other Macs run models on this one.
struct LendSettings: View {
    @ObservedObject private var lender = MacLender.shared
    @State private var pairing = false

    var body: some View {
        Form {
            Section {
                Toggle("Lend this Mac", isOn: $lender.enabled)
                Text("Your other Macs can run models on this one. Only machines you pair with a code can use it, and only while Frog is open. It uses this Mac's GPU and memory while they do, and it never keeps this Mac awake.")
                    .font(.frog(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Keep lending on battery", isOn: $lender.onBattery)
                    .help("Off: lending pauses when you unplug and resumes on power.")
                LabeledContent("Status") { status }
            }
            .disabled(!lender.enabled)
            Section {
                HStack {
                    Text("Pair another Mac with this one by typing a code on it.")
                        .font(.frog(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Pair a Mac…") { pairing = true }
                        .disabled(lender.state != .running)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $pairing) { PairCodeSheet() }
    }

    @ViewBuilder private var status: some View {
        switch lender.state {
        case .off: Text("Off").foregroundStyle(.secondary)
        case .starting: Text("Starting…").foregroundStyle(.secondary)
        case .running: Label("Lending on port \(String(MacLender.port))", systemImage: "circle.fill")
            .labelStyle(StatusDot())
        case .paused(let why): Text(why).foregroundStyle(.secondary)
        case .failed(let why): Text(why).foregroundStyle(.red)
        }
    }
}

private struct StatusDot: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Circle().fill(.green).frame(width: 7, height: 7)
            configuration.title
        }
    }
}

/// The 6-digit code from `POST /pair/open`, big, with this Mac's fingerprint and a countdown.
private struct PairCodeSheet: View {
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
