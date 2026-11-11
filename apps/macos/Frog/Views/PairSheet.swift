import SwiftUI

/// The quiet line above the composer when a node frog hasn't paired shows up on the network:
/// "mew is on your network · RTX 3090 · 24 GB. Use it?" [Use it] [Not now].
struct NodeOffer: View {
    @State private var devices = Devices.shared
    @State private var pairing: Device?

    var body: some View {
        Group {
            if let d = devices.offer {
                NodeOfferRow(device: d, use: { pairing = d }, dismiss: { devices.dismiss(d.id) })
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.25), value: devices.offer?.id)
        .sheet(item: $pairing) { d in PairSheet(device: d) }
        .onAppear { devices.start() }
        .onDisappear { devices.stop() }
    }

    /// "mew is on your network · RTX 3090 · 24 GB. Use it?"
    static func line(_ d: Device) -> String {
        let mem = d.totalBytes > 0 ? "\(Int((Double(d.totalBytes) / 1_073_741_824).rounded())) GB" : nil
        let parts = ["\(d.name) is on your network", d.chip.isEmpty ? nil : d.chip, mem].compactMap { $0 }
        return parts.joined(separator: " · ") + ". Use it?"
    }
}

/// The notice's one line and its two buttons.
struct NodeOfferRow: View {
    let device: Device
    let use: () -> Void
    let dismiss: () -> Void

    var body: some View {
        let d = device
                HStack(spacing: 8) {
                    Image(systemName: d.kind == "metal" ? "desktopcomputer" : "server.rack")
                        .foregroundStyle(Tokens.textSecondary)
                    Text(NodeOffer.line(d))
                        .foregroundStyle(Tokens.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Not now", action: dismiss)
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.textTertiary)
                    Button("Use it", action: use)
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.text)
                        .fontWeight(.medium)
                }
                .font(.frog(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous).fill(Tokens.raised))
    }
}

/// Type the code the node shows. One job: six digits, then the node joins.
struct PairSheet: View {
    let device: Device
    @State private var devices = Devices.shared
    @State private var digits: [String]
    @State private var problem: String?
    @State private var working = false
    @State private var done = false
    @FocusState private var focus: Int?
    @Environment(\.dismiss) private var dismiss

    /// `code` and `problem` preset the fields (snapshots).
    init(device: Device, code: String = "", problem: String? = nil) {
        self.device = device
        _digits = State(initialValue: (0..<6).map { i in
            i < code.count ? String(code[code.index(code.startIndex, offsetBy: i)]) : ""
        })
        _problem = State(initialValue: problem)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: device.kind == "metal" ? "desktopcomputer" : "server.rack")
                    .foregroundStyle(Tokens.textSecondary)
                Text("Use \(device.name)")
                    .font(.frog(size: 15, weight: .semibold))
            }
            Group {
                if live.pairOpen {
                    Text("\(device.name) is showing a code. Type it here.")
                } else {
                    Text("On \(device.name), run ") + Text("tang-llm pair").font(.system(size: 13, design: .monospaced)) // advanced: the command to type
                        + Text(" and type the code it shows.")
                }
            }
            .font(.frog(size: 13))
            .foregroundStyle(Tokens.textSecondary)

            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    TextField("", text: binding(i))
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 40, height: 48)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Tokens.raised))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(focus == i ? Tokens.textTertiary : .clear, lineWidth: 1))
                        .focused($focus, equals: i)
                        .disabled(working || done)
                    if i == 2 { Spacer().frame(width: 6) }
                }
            }

            Group {
                if done {
                    Label("\(device.name) joined your machines.", systemImage: "checkmark.circle.fill")
                        .labelStyle(StateGlyph(color: Tokens.accent))
                } else if let problem {
                    Label(problem, systemImage: "exclamationmark.circle.fill")
                        .labelStyle(StateGlyph(color: Tokens.fail))
                } else if working {
                    Text("Pairing…").foregroundStyle(Tokens.textTertiary)
                } else if let fp = device.fingerprint {
                    Text("\(device.name)'s fingerprint: \(PairCrypto.grouped(fp))")
                        .foregroundStyle(Tokens.textTertiary)
                        .monospacedDigit()
                } else {
                    Text(" ")
                }
            }
            .font(.frog(size: 12))
            .frame(minHeight: 16, alignment: .leading)

            HStack {
                Spacer()
                Button(done ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !done {
                    Button("Pair") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(code.count != 6 || working)
                }
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(FrogCanvas.color)
        .onAppear { focus = 0 }
    }

    /// The device as Devices sees it now (the code window can open while the sheet is up).
    private var live: Device { devices.list.first { $0.id == device.id } ?? device }

    private var code: String { digits.joined() }

    private func binding(_ i: Int) -> Binding<String> {
        Binding {
            digits[i]
        } set: { new in
            let only = new.filter(\.isNumber)
            problem = nil
            // A pasted code fills every field.
            if only.count == 6 {
                digits = only.map(String.init)
                focus = 5
                submit()
                return
            }
            digits[i] = only.last.map(String.init) ?? ""
            if !digits[i].isEmpty {
                if i < 5 { focus = i + 1 } else { submit() }
            }
        }
    }

    private func submit() {
        guard code.count == 6, !working else { return }
        working = true
        problem = nil
        let c = code
        Task {
            do {
                try await devices.pair(device.id, code: c)
                done = true
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            } catch let e as PairError {
                problem = e.line(device.name)
                digits = Array(repeating: "", count: 6)
                focus = 0
            } catch {
                problem = PairError.network(error.localizedDescription).line(device.name)
            }
            working = false
        }
    }
}

/// A label whose glyph carries the state color and whose words stay plain.
private struct StateGlyph: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(color)
            configuration.title.foregroundStyle(Tokens.textSecondary)
        }
    }
}
