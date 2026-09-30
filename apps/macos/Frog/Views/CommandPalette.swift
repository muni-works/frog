import SwiftUI

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var subtitle: String = ""
    let symbol: String
    let run: () -> Void
}

extension Workspace {
    /// Everything the palette can do, right now.
    func commands(showChanges: Binding<Bool>) -> [PaletteCommand] {
        var out: [PaletteCommand] = [
            PaletteCommand(id: "new", title: "New Session", subtitle: "⇧⌘N", symbol: "square.and.pencil") { self.newSession() },
            PaletteCommand(id: "changes", title: showChanges.wrappedValue ? "Hide Changes" : "Show Changes", subtitle: "⌥⌘0", symbol: "plusminus") {
                showChanges.wrappedValue.toggle()
            },
        ]
        if let c = conversation {
            if !c.busy, !c.turns.isEmpty {
                out.append(PaletteCommand(id: "compact", title: "Compact Conversation", subtitle: "Summarize to free context", symbol: "arrow.down.right.and.arrow.up.left") { c.compact() })
            }
            if c.busy {
                out.append(PaletteCommand(id: "interrupt", title: "Interrupt", subtitle: "Esc", symbol: "stop.fill") { c.interrupt() })
            }
            if let last = c.turns.last(where: { $0.finished && $0.number != nil }), let n = last.number {
                out.append(PaletteCommand(id: "fork", title: "Fork After Last Turn", subtitle: last.request, symbol: "arrow.triangle.branch") { self.fork(afterTurn: n) })
            }
            for mode in Mode.allCases where mode != c.status?.mode {
                out.append(PaletteCommand(id: "mode-\(mode.rawValue)", title: "Mode: \(mode.label)", symbol: mode.symbol) { c.setMode(mode) })
            }
            for m in models where m.spec != c.status?.model {
                let id = ModelIdentity(m)
                out.append(PaletteCommand(id: "model-\(m.spec)", title: "Model: \(id.name)", subtitle: id.place.label, symbol: id.place.symbol) {
                    self.use(m.spec)
                })
            }
        }
        for s in sessions where s.id != conversation?.sessionID {
            out.append(PaletteCommand(id: "session-\(s.id)", title: s.displayTitle, subtitle: ModelIdentity.of(s.model, in: models).name, symbol: s.forkedFrom == nil ? "bubble.left" : "arrow.triangle.branch") {
                self.selection = s.id
                self.open(s.id)
            })
        }
        return out
    }
}

struct CommandPalette: View {
    let commands: [PaletteCommand]
    let dismiss: () -> Void
    @State private var query = ""
    @State private var picked = 0
    @FocusState private var focused: Bool

    private var matches: [PaletteCommand] {
        guard !query.isEmpty else { return Array(commands.prefix(12)) }
        let hits = Set(FileIndex.search(commands.map(\.title), query, limit: 12))
        return commands.filter { hits.contains($0.title) }
    }

    var body: some View {
        let list = matches
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField("Type a command or session…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(list) }
                    .onKeyPress(.upArrow) { picked = max(0, picked - 1); return .handled }
                    .onKeyPress(.downArrow) { picked = min(list.count - 1, picked + 1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .onChange(of: query) { picked = 0 }
            }
            .padding(14)
            if !list.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, cmd in
                            Button { cmd.run(); dismiss() } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: cmd.symbol).frame(width: 20).foregroundStyle(.secondary)
                                    Text(cmd.title).lineLimit(1)
                                    Spacer(minLength: 12)
                                    Text(cmd.subtitle).foregroundStyle(.secondary).lineLimit(1).font(.callout)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(i == picked ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .onAppear { focused = true }
    }

    private func run(_ list: [PaletteCommand]) {
        guard list.indices.contains(picked) else { return }
        list[picked].run()
        dismiss()
    }
}
