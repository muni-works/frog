import AppKit
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
    /// Images to send with the message.
    @State private var attachments: [ToolImage] = []
    @Environment(\.switchFolder) private var switchFolder

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
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
            field
            controls
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
        // The transcript scrolls under the composer; the canvas fades in behind it.
        .background {
            LinearGradient(
                stops: [.init(color: KilnCanvas.color.opacity(0), location: 0), .init(color: KilnCanvas.color, location: 0.25)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    /// Before the first message: where the conversation works (a folder, or none for a plain
    /// chat). After it: the repository's branch and changes, for a folder in git.
    @ViewBuilder
    private var topRow: some View {
        if conversation.turns.isEmpty, !conversation.replaying {
            ContextBar {
                // Its hover plate's margin, so the text lines up with the git bar's.
                FolderChip(folder: workspace.folder, choose: switchFolder)
                    .padding(.leading, -7)
                Spacer(minLength: 0)
            }
        } else if !workspace.isChat, let git = workspace.git {
            GitBar(folder: workspace.folder, git: git, busy: conversation.busy) {
                conversation.submit("Commit the current changes: review the diff, stage only files related to our work, and write a clear, concise commit message.")
            }
        }
    }

    private static let fieldShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    private var field: some View {
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
            if !attachments.isEmpty {
                AttachmentStrip(images: $attachments, blind: conversation.status?.vision == false ? conversation.status?.model : nil)
            }
            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
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
                        onMentionKey: handleMentionKey,
                        onPasteImages: { attachments += $0 }
                    )
                    .frame(height: height)
                }
                sendButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(KilnCanvas.color, in: Self.fieldShape)
        .overlay(Self.fieldShape.fill(Color.primary.opacity(0.045)).allowsHitTesting(false))
        .overlay(Self.fieldShape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
        .contentShape(Self.fieldShape)
        .onTapGesture { controller.focus() }
        .animation(.snappy, value: conversation.toast)
        .onChange(of: window?.focusComposerRequest) { controller.focus() }
        .onChange(of: skillSuggestions.map(\.name)) { picked = 0 }
        .onChange(of: window?.raceRequest) {
            controller.focus()
            racing = true
        }
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
        // Drops land on the whole conversation (see `ConversationDropZone`) and arrive here.
        .onChange(of: conversation.dropped) { _, urls in
            guard !urls.isEmpty else { return }
            conversation.dropped = []
            accept(urls)
        }
    }

    private var placeholder: String {
        if conversation.busy { return "Working… Esc interrupts · Return queues a follow-up" }
        return workspace.isChat ? "Ask anything" : "Ask kiln to do something · @ mentions a file"
    }

    /// Send while there's something to send; stop while a turn runs and the field is empty.
    @ViewBuilder
    private var sendButton: some View {
        if conversation.busy, !canSend {
            Button { conversation.interrupt() } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .hoverPlate(h: 3, v: 3)
            }
            .buttonStyle(.plain)
            .help("Interrupt (Esc or ⌘.)")
        } else {
            Button(action: send) {
                Image(systemName: "return")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 22, height: 22)
                    .hoverPlate(h: 3, v: 3)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(conversation.busy ? "Queue (Return)" : "Send (Return)")
        }
    }

    /// Under the field, without chrome: add things on the left, how kiln works on the right.
    private var controls: some View {
        HStack(spacing: 8) {
            plusMenu
            ModePicker(conversation: conversation)
            Spacer()
            if let e = workspace.raceError {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(e)
            }
            ModelPicker(workspace: workspace, conversation: conversation)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
    }

    private var plusMenu: some View {
        Menu {
            Button("Attach Images…", systemImage: "photo") { attachFromPanel() }
            if !workspace.isChat {
                Button("Mention a File", systemImage: "at") {
                    controller.focus()
                    controller.insert("@")
                }
            }
            if !workspace.skills.isEmpty {
                Button("Use a Skill", systemImage: "wand.and.stars") {
                    controller.focus()
                    controller.replaceAll("/")
                }
                .disabled(!text.isEmpty)
            }
            if !workspace.isChat {
                Divider()
                Button("Race Attempts…", systemImage: "square.stack.3d.up") { racing = true }
                    .disabled(!canSend || conversation.busy)
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 22, height: 22)
                .hoverPlate(h: 3, v: 3)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Attach images, mention a file, use a skill, or race attempts")
        .popover(isPresented: $racing, arrowEdge: .top) {
            RaceSetup(workspace: workspace, prompt: text) { models, check in
                racing = false
                workspace.startRace(prompt: text, models: models, check: check)
                text = ""
            }
        }
    }

    /// Images attach; other files become `@` mentions, relative to the project when inside it.
    private func accept(_ urls: [URL]) {
        attachments += urls.filter(Attachments.isImage).compactMap(Attachments.image(at:))
        let files = urls.filter { !Attachments.isImage($0) }
        guard !files.isEmpty else { return }
        let root = conversation.folder.standardizedFileURL.path + "/"
        let mentions = files.map { url in
            let p = url.standardizedFileURL.path
            return "@" + (p.hasPrefix(root) ? String(p.dropFirst(root.count)) : p)
        }
        controller.insert(mentions.joined(separator: " ") + " ")
    }

    private func send() {
        guard canSend else { return }
        conversation.submit(text, images: attachments)
        text = ""
        attachments = []
        mention = nil
    }

    private func attachFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Attach images to your message"
        guard panel.runModal() == .OK else { return }
        attachments += panel.urls.compactMap(Attachments.image(at:))
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
            HStack(spacing: 4) {
                Text(mode.label)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(mode == .yolo ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .hoverPlate()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
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
            HStack(spacing: 4) {
                Text(conversation.status.map { short($0.model) } ?? "Model")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .hoverPlate()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(conversation.status.map { "\($0.toolMode) tool calls · \($0.tier) tier" } ?? "Model")
    }

    /// "ollama/qwen3:4b" → "qwen3:4b"; the full spec is in the menu.
    private func short(_ spec: String) -> String {
        spec.split(separator: "/").last.map(String.init) ?? spec
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
        ContextBar {
            Text(folder.lastPathComponent)
            Text(git.branch).foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            if git.changed > 0 {
                HStack(spacing: 6) {
                    if git.added + git.removed > 0 {
                        Text("+\(git.added)").foregroundStyle(.green)
                        Text("−\(git.removed)").foregroundStyle(.red)
                    } else {
                        Text("\(git.changed) new").foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 7))
                .help("\(git.changed) file\(git.changed == 1 ? "" : "s") with uncommitted changes")
                Button(action: commit) {
                    Text("Commit changes")
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 7))
                        .hoverPlate(h: 0, v: 0)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .help("Ask kiln to commit the current changes")
            }
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
    }
}

/// The flat bar above the composer: where the conversation works, and what's changed there.
struct ContextBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.leading, 14)
            .padding(.trailing, 7)
            .frame(height: 38)
            .background(KilnCanvas.color, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)).allowsHitTesting(false))
    }
}

/// Images waiting to be sent: thumbnails with a remove button, and a note when the model can't
/// see them.
struct AttachmentStrip: View {
    @Binding var images: [ToolImage]
    /// The model's name, when it can't see images.
    let blind: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                        if let data = Data(base64Encoded: img.data), let ns = NSImage(data: data) {
                            Image(nsImage: ns)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 56, height: 56)
                                .clipShape(.rect(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                                .opensInLightbox(images, at: i)
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        images.remove(at: i)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 5, y: -5)
                                    .help("Remove")
                                }
                        }
                    }
                }
                .padding(.top, 6)
                .padding(.trailing, 6)
            }
            .scrollIndicators(.never)
            if let blind {
                Label("\(blind) can't see images; pick a vision model (like gemma3 or qwen2.5vl) to include them.", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
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
                    .hoverPlate(h: 0, v: 0)
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
                    .hoverPlate(h: 0, v: 0)
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
            ForEach(Array(conversation.queue.map(\.text).enumerated()), id: \.offset) { i, text in
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

extension View {
    /// A soft rounded plate behind a plain control while the pointer is over it, so chromeless
    /// buttons and menus still answer the pointer. The padding is the plate's margin.
    func hoverPlate(h: CGFloat = 7, v: CGFloat = 3, radius: CGFloat = 7) -> some View {
        modifier(HoverPlate(h: h, v: v, radius: radius))
    }
}

private struct HoverPlate: ViewModifier {
    let h: CGFloat
    let v: CGFloat
    let radius: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, h)
            .padding(.vertical, v)
            .background(Color.primary.opacity(hovering && enabled ? 0.08 : 0), in: .rect(cornerRadius: radius, style: .continuous))
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
