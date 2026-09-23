import SwiftUI

struct ComposerView: View {
    let workspace: Workspace
    let conversation: Conversation
    var window: WindowState?
    @State private var text = ""
    @State private var height: CGFloat = 22
    @State private var controller = ComposerController()
    @State private var mention: String?
    @State private var picked = 0
    @State private var racing = false
    @State private var dropTargeted = false
    @Environment(\.switchFolder) private var switchFolder

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var suggestions: [String] {
        guard let mention else { return [] }
        return FileIndex.search(workspace.files, mention)
    }

    /// `/sk…` at the start of the message: matching skills.
    private var skillSuggestions: [SkillInfo] {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        let q = text.dropFirst().lowercased()
        let all = workspace.skills
        let prefix = all.filter { $0.name.hasPrefix(q) }
        let rest = q.isEmpty ? [] : all.filter { !$0.name.hasPrefix(q) && ($0.name.contains(q) || $0.description.lowercased().contains(q)) }
        return Array((prefix + rest).prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
                .opacity(suggestions.isEmpty && skillSuggestions.isEmpty ? 1 : 0)
            box
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: 860)
    }

    /// Before the first message: where the conversation works (a folder, or none for a plain
    /// chat). After it: the repository's branch and changes, for a folder in git.
    @ViewBuilder
    private var topRow: some View {
        if conversation.turns.isEmpty, !conversation.replaying {
            FolderChip(folder: workspace.folder, choose: switchFolder)
        } else if !workspace.isChat, let git = workspace.git {
            GitBar(folder: workspace.folder, git: git, busy: conversation.busy) {
                conversation.submit("Commit the current changes: review the diff, stage only files related to our work, and write a clear, concise commit message.")
            }
        }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let toast = conversation.toast {
                Label(toast, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !conversation.queue.isEmpty {
                QueuedMessages(conversation: conversation)
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(conversation.busy ? "Working… Esc interrupts · Return queues a follow-up" : workspace.skills.isEmpty ? "Ask kiln to do something · @ to mention a file" : "Ask kiln to do something · @ to mention a file · / for skills")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                ComposerTextView(
                    text: $text,
                    height: $height,
                    controller: controller,
                    onSubmit: send,
                    onEscape: {
                        guard conversation.busy else { return false }
                        conversation.interrupt()
                        return true
                    },
                    onMention: { query in
                        if query != nil { workspace.loadFiles() }
                        if query != mention { picked = 0 }
                        mention = query
                    },
                    onMentionKey: handleMentionKey
                )
                .frame(height: height)
            }

            HStack(spacing: 10) {
                ModePicker(conversation: conversation)
                ModelPicker(workspace: workspace, conversation: conversation)
                Spacer()
                if let e = workspace.raceError {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(e)
                }
                Button {
                    racing = true
                } label: {
                    Image(systemName: "square.stack.3d.up")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(!canSend || conversation.busy)
                .accessibilityLabel("Race")
                .help("Race: run this prompt as several parallel attempts (⌥⌘R)")
                .popover(isPresented: $racing, arrowEdge: .top) {
                    RaceSetup(workspace: workspace, prompt: text) { models, check in
                        racing = false
                        workspace.startRace(prompt: text, models: models, check: check)
                        text = ""
                    }
                }
                if conversation.busy, !canSend {
                    Button {
                        conversation.interrupt()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Interrupt (Esc or ⌘.)")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .disabled(!canSend)
                    .help(conversation.busy ? "Queue (Return)" : "Send (Return)")
                }
            }
        }
        .padding(12)
        .animation(.snappy, value: conversation.toast)
        .onChange(of: window?.focusComposerRequest) { controller.focus() }
        .onChange(of: skillSuggestions.map(\.name)) { picked = 0 }
        .onChange(of: window?.raceRequest) {
            controller.focus()
            racing = true
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        // Completions float above the composer, outside its glass (which would clip them).
        .overlay(alignment: .topLeading) {
            Group {
                if !suggestions.isEmpty {
                    MentionList(files: suggestions, picked: picked) { controller.insertMention($0) }
                } else if !skillSuggestions.isEmpty {
                    SkillList(skills: skillSuggestions, picked: picked) { controller.replaceAll("/\($0.name) ") }
                }
            }
            .fixedSize()
            .alignmentGuide(.top) { $0[.bottom] + 8 }
            .padding(.leading, 12)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 20).strokeBorder(.tint, lineWidth: 2)
            }
        }
        // Drop files to mention them: `@path` relative to the project when inside it.
        .dropDestination(for: URL.self) { urls, _ in
            let root = conversation.folder.standardizedFileURL.path + "/"
            let mentions = urls.map { url in
                let p = url.standardizedFileURL.path
                return "@" + (p.hasPrefix(root) ? String(p.dropFirst(root.count)) : p)
            }
            controller.insert(mentions.joined(separator: " ") + " ")
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    private func send() {
        guard canSend else { return }
        conversation.submit(text)
        text = ""
        mention = nil
    }

    private func handleMentionKey(_ key: MentionKey) -> Bool {
        let skills = skillSuggestions
        if suggestions.isEmpty, !skills.isEmpty {
            switch key {
            case .up: picked = (picked - 1 + skills.count) % skills.count
            case .down: picked = (picked + 1) % skills.count
            case .accept: controller.replaceAll("/\(skills[min(picked, skills.count - 1)].name) ")
            case .cancel: controller.replaceAll("")
            }
            return true
        }
        let list = suggestions
        guard !list.isEmpty else { return false }
        switch key {
        case .up: picked = (picked - 1 + list.count) % list.count
        case .down: picked = (picked + 1) % list.count
        case .accept: controller.insertMention(list[min(picked, list.count - 1)])
        case .cancel: mention = nil
        }
        return true
    }
}

struct ModePicker: View {
    let conversation: Conversation

    var body: some View {
        let mode = conversation.status?.mode ?? .default
        Menu {
            ForEach(Mode.allCases) { m in
                Button {
                    conversation.setMode(m)
                } label: {
                    Label(m.label, systemImage: m.symbol)
                }
            }
        } label: {
            Label(mode.label, systemImage: mode.symbol)
                .font(.callout)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .tint(mode == .yolo ? .orange : nil)
        .help("Permission mode")
    }
}

struct ModelPicker: View {
    let workspace: Workspace
    let conversation: Conversation

    var body: some View {
        Menu {
            ForEach(workspace.models) { m in
                Button {
                    workspace.preferredModel = m.spec
                    conversation.setModel(m.spec)
                } label: {
                    Text(m.spec)
                    Text(detail(m))
                }
            }
        } label: {
            Label(conversation.status?.model ?? "Model", systemImage: "cpu")
                .font(.callout)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help(conversation.status.map { "\($0.toolMode) tool calls · \($0.tier) tier" } ?? "Model")
    }

    private func detail(_ m: ModelEntry) -> String {
        var parts = ["\(m.toolMode) tools", "\(m.tier) tier"]
        if let b = m.caps?.paramsB { parts.insert(String(format: "%.1fB", b), at: 0) }
        if m.caps == nil, m.source == "ollama" { parts.append("not profiled yet") }
        return parts.joined(separator: " · ")
    }
}

struct ContextRing: View {
    let status: Status

    private var fraction: Double {
        guard let used = status.contextTokens, status.contextWindow > 0 else { return 0 }
        return min(1, Double(used) / Double(status.contextWindow))
    }

    private var color: Color {
        fraction > 0.8 ? .red : fraction > 0.6 ? .orange : .secondary
    }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .animation(.smooth, value: fraction)
        .help(helpText)
    }

    private var helpText: String {
        let window = status.contextWindow.tokens
        guard let used = status.contextTokens else { return "Context window: \(window) tokens" }
        return "\(used.tokens) of \(window) tokens (\(Int(fraction * 100))%)"
    }
}

/// The repository a conversation works in: folder, branch, and a shortcut to commit what's
/// changed.
struct GitBar: View {
    let folder: URL
    let git: GitInfo
    let busy: Bool
    let commit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(folder.lastPathComponent, systemImage: "folder")
            Label(git.branch, systemImage: "arrow.triangle.branch")
            if git.changed > 0 {
                Text("\(git.changed) changed").foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if git.changed > 0 {
                Button("Commit changes", action: commit)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(busy)
                    .help("Ask kiln to commit the current changes")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
    }
}

/// `/skill` completions: name and what it's for.
struct SkillList: View {
    let skills: [SkillInfo]
    let picked: Int
    let choose: (SkillInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(skills.enumerated()), id: \.element) { i, skill in
                Button {
                    choose(skill)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles.rectangle.stack").foregroundStyle(.secondary)
                            Text("/" + skill.name).fontWeight(.medium)
                            if skill.project {
                                Text("project").font(.caption2).foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.quaternary, in: .capsule)
                            }
                        }
                        Text(skill.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 22)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(i == picked ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 480, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

struct MentionList: View {
    let files: [String]
    let picked: Int
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.element) { i, path in
                Button {
                    choose(path)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text((path as NSString).lastPathComponent).fontWeight(.medium)
                        let dir = (path as NSString).deletingLastPathComponent
                        Text(dir).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(i == picked ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 420, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

struct QueuedMessages: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(conversation.queue.enumerated()), id: \.offset) { i, text in
                HStack(spacing: 6) {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    Text(text).lineLimit(1)
                    Spacer()
                    Button("Remove", systemImage: "xmark.circle.fill") { conversation.unqueue(at: i) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(.horizontal, 4)
    }
}
