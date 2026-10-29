import SwiftUI

/// Mission control for a race: one card per attempt, live, with its changes and check result.
struct RaceView: View {
    let race: Race
    let onClose: () -> Void
    @State private var inspecting: Race.Attempt?
    @State private var applying: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let e = race.error {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                    ForEach(race.attempts) { attempt in
                        AttemptCard(
                            attempt: attempt,
                            best: bestIDs.contains(attempt.id),
                            applying: applying == attempt.id,
                            apply: { apply(attempt.id) },
                            inspect: { inspecting = attempt }
                        )
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .padding(24)
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

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(race.attempts.count) attempts in parallel", systemImage: "square.stack.3d.up")
                    .font(.frog(size: 13, weight: .semibold))
                Text(race.prompt)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if let check = race.checkCommand {
                    Label(check, systemImage: "checkmark.seal")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(race.applied == nil ? "Discard All" : "Close", role: race.applied == nil ? .destructive : nil) {
                if race.applied == nil { race.discard() }
                onClose()
            }
            .buttonStyle(.glass)
        }
    }

    /// Attempts that passed the check (or, without a check, none are singled out).
    private var bestIDs: Set<Int> {
        Set(race.attempts.filter { if case .passed = $0.check { true } else { false } }.map(\.id))
    }

    private func apply(_ i: Int) {
        applying = i
        Task {
            if await race.apply(i) { onClose() }
            applying = nil
        }
    }
}

private struct AttemptCard: View {
    @Environment(\.models) private var models
    let attempt: Race.Attempt
    let best: Bool
    let applying: Bool
    let apply: () -> Void
    let inspect: () -> Void

    var body: some View {
        let c = attempt.conversation
        let turn = c.turns.last
        let parts = turn.map(TurnParts.init)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Attempt \(attempt.id + 1)").font(.frog(size: 13, weight: .semibold))
                Spacer()
                ModelLabel(model: ModelIdentity.of(attempt.model, in: models), size: .caption)
                    .font(.frog(size: 10))
            }
            status(turn)
            if let turn, !turn.finished {
                RecentSteps(items: Array(turn.items.suffix(3)))
            }
            if let parts, !parts.changes.isEmpty {
                FlowChips(changes: parts.changes)
            }
            if let answer = parts?.answer.last?.text, !answer.isEmpty {
                Text(answer)
                    .font(.frog(size: 12))
                    .lineLimit(4)
                    .foregroundStyle(.secondary)
            }
            if let check = attempt.check {
                checkView(check)
            }
            Spacer(minLength: 0)
            HStack {
                Button("View", systemImage: "text.alignleft", action: inspect)
                    .buttonStyle(.glass)
                Spacer()
                Button {
                    apply()
                } label: {
                    if applying { ProgressView().controlSize(.small) } else { Text("Apply") }
                }
                .buttonStyle(.glassProminent)
                .disabled(!attempt.finished || (parts?.changes.isEmpty ?? true) || applying)
                .help("Apply this attempt's changes to the project and discard the others")
            }
        }
        .padding(14)
        .frame(minHeight: 220, alignment: .top)
        .glassEffect(best ? .regular.tint(.green.opacity(0.18)) : .regular, in: .rect(cornerRadius: 16))
        .overlay {
            if best {
                RoundedRectangle(cornerRadius: 16).strokeBorder(.green.opacity(0.6), lineWidth: 1.5)
            }
        }
    }

    @ViewBuilder
    private func status(_ turn: TurnState?) -> some View {
        if let turn, let end = turn.end {
            switch end {
            case .complete: Label("Done", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            case .error(let e): Label(e.description, systemImage: "exclamationmark.octagon").foregroundStyle(.red).lineLimit(2)
            default: Label("Stopped", systemImage: "stop.circle").foregroundStyle(.orange)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(liveLine(turn)).lineLimit(1).foregroundStyle(.secondary)
                }
            }
            .font(.frog(size: 12))
        }
    }

    private func liveLine(_ turn: TurnState?) -> String {
        guard let turn, let last = turn.items.last else { return "Starting…" }
        let secs = turn.startedAt.map { Int(Date.now.timeIntervalSince($0)) } ?? 0
        switch last.kind {
        case .tool(let name, let arg): return "\(secs)s · \(name) \(arg)"
        case .reasoning: return "\(secs)s · thinking"
        default: return "\(secs)s · writing"
        }
    }

    @ViewBuilder
    private func checkView(_ check: Race.Check) -> some View {
        switch check {
        case .running:
            Label("Running check…", systemImage: "hourglass").font(.frog(size: 12)).foregroundStyle(.secondary)
        case .passed:
            Label("Check passed", systemImage: "checkmark.seal.fill").font(.callout.weight(.medium)).foregroundStyle(.green)
        case .failed(let out):
            VStack(alignment: .leading, spacing: 4) {
                Label("Check failed", systemImage: "xmark.seal.fill").font(.callout.weight(.medium)).foregroundStyle(.red)
                Text(out.split(separator: "\n").suffix(2).joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct RecentSteps: View {
    let items: [ItemState]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    switch item.kind {
                    case .tool(let name, let arg):
                        Image(systemName: ToolIcon.symbol(name)).frame(width: 14)
                        Text(name).fontWeight(.medium)
                        Text(arg).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    case .reasoning:
                        Image(systemName: "sparkles").frame(width: 14)
                        Text(item.text.split(separator: "\n").last.map(String.init) ?? "Thinking").lineLimit(1)
                    case .message:
                        Image(systemName: "text.bubble").frame(width: 14)
                        Text(item.text).lineLimit(1)
                    case .notice:
                        Image(systemName: "info.circle").frame(width: 14)
                        Text(item.text).lineLimit(1)
                    }
                }
                .font(.frog(size: 10))
                .foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.snappy, value: items.map(\.id))
    }
}

private struct FlowChips: View {
    let changes: [FileChange]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(changes.prefix(3)) { c in
                HStack(spacing: 4) {
                    Text(c.name).fontWeight(.medium)
                    Text("+\(c.added)").foregroundStyle(.green)
                    Text("−\(c.removed)").foregroundStyle(.red)
                }
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: .capsule)
                .fileActions(c.path)
            }
            if changes.count > 3 {
                Text("+\(changes.count - 3) more").font(.frog(size: 10)).foregroundStyle(.secondary)
            }
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
