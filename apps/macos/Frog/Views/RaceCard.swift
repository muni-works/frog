import SwiftUI

/// A race's outcome, as one card at the foot of the conversation: a line per attempt (its
/// model, where it is, its check, what it changed) with View and Apply, and Discard for all.
/// Applying one lands its changes in the project and removes the others' worktrees.
struct RaceCard: View {
    @Environment(\.models) private var models
    let race: Race
    let onClose: () -> Void
    @State private var inspecting: Race.Attempt?
    @State private var applying: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Racing \(race.attempts.count) attempts", systemImage: "square.stack.3d.up")
                    .font(.frog(size: 12, weight: .semibold))
                Text(race.prompt).lineLimit(1).foregroundStyle(.secondary)
                Spacer()
                Button(race.applied == nil ? "Discard All" : "Close", role: race.applied == nil ? .destructive : nil) {
                    if race.applied == nil { race.discard() }
                    onClose()
                }
                .buttonStyle(.borderless)
            }
            if let e = race.error {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(race.attempts) { attempt in row(attempt) }
        }
        .font(.frog(size: 12))
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .sheet(item: $inspecting) { attempt in
            VStack(spacing: 0) {
                HStack {
                    Text("Attempt \(attempt.id + 1) · \(attempt.model)").font(.frog(size: 13, weight: .semibold))
                    Spacer()
                    Button("Done") { inspecting = nil }.keyboardShortcut(.cancelAction)
                }
                .padding()
                TranscriptView(conversation: attempt.conversation, actions: TurnActions(fork: { _ in }, rewind: { _ in }))
            }
            .frame(minWidth: 760, minHeight: 600)
        }
    }

    private func row(_ attempt: Race.Attempt) -> some View {
        let parts = attempt.conversation.turns.last.map(TurnParts.init)
        let changes = parts?.changes ?? []
        return HStack(spacing: 8) {
            Text("\(attempt.id + 1)").monospacedDigit().foregroundStyle(.secondary)
            ModelLabel(model: ModelIdentity.of(attempt.model, in: models), size: .caption)
            status(attempt)
            if let check = attempt.check { checkLabel(check) }
            if !changes.isEmpty {
                Text("\(changes.count) file\(changes.count == 1 ? "" : "s") · +\(changes.map(\.added).reduce(0, +)) −\(changes.map(\.removed).reduce(0, +))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("View") { inspecting = attempt }.buttonStyle(.borderless)
            Button {
                apply(attempt.id)
            } label: {
                if applying == attempt.id { ProgressView().controlSize(.small) } else { Text("Apply") }
            }
            .disabled(!attempt.finished || changes.isEmpty || applying != nil || race.applied != nil)
            .help("Apply this attempt's changes to the project and discard the others")
        }
    }

    @ViewBuilder
    private func status(_ attempt: Race.Attempt) -> some View {
        if let end = attempt.conversation.turns.last?.end {
            switch end {
            case .complete: Text("done").foregroundStyle(.secondary)
            case .error(let e): Text(e.description).lineLimit(1).foregroundStyle(.red)
            default: Text("stopped").foregroundStyle(.orange)
            }
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    @ViewBuilder
    private func checkLabel(_ check: Race.Check) -> some View {
        switch check {
        case .running: Image(systemName: "hourglass").foregroundStyle(.secondary).help("Running the check")
        case .passed: Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help("Check passed")
        case .failed(let out):
            Image(systemName: "xmark.seal.fill").foregroundStyle(.red)
                .help(out.split(separator: "\n").suffix(4).joined(separator: "\n"))
        }
    }

    private func apply(_ i: Int) {
        applying = i
        Task {
            if await race.apply(i) { onClose() }
            applying = nil
        }
    }
}

/// Composer popover: how many attempts, which models, and an optional check.
struct RaceSetup: View {
    let workspace: Workspace
    let prompt: String
    let start: (_ models: [String], _ check: String?) -> Void
    @State private var count = 3
    @State private var models: [String] = []
    @AppStorage("raceCheck") private var check = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Race this prompt").font(.frog(size: 13, weight: .semibold))
            Text("Runs several attempts at once, each in its own git worktree, so you can pick the best one.")
                .font(.frog(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Stepper("\(count) attempts", value: $count, in: 2...4)
            ForEach(0..<count, id: \.self) { i in
                Picker("Attempt \(i + 1)", selection: binding(i)) {
                    ForEach(workspace.models) { m in ModelLabel(model: ModelIdentity(m), size: .menu).tag(m.spec) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Check (optional)").font(.callout.weight(.medium))
                TextField("e.g. python3 -m pytest", text: $check)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("Runs in each attempt's worktree when it finishes; passing attempts are highlighted.")
                    .font(.frog(size: 10))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Start \(count) Attempts") {
                    start((0..<count).map { model(at: $0) }, check)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            let current = workspace.conversation?.status?.model ?? workspace.models.first?.spec ?? ""
            models = Array(repeating: current, count: 4)
        }
    }

    private func model(at i: Int) -> String {
        models.indices.contains(i) ? models[i] : (workspace.models.first?.spec ?? "")
    }

    private func binding(_ i: Int) -> Binding<String> {
        Binding(get: { model(at: i) }, set: { v in if models.indices.contains(i) { models[i] = v } })
    }
}
