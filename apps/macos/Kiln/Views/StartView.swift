import AppKit
import SwiftUI

/// The folder a conversation works in, as a chip above the composer. The menu lists recent
/// folders and a chooser. `choose` handles the pick; without it, a pick opens a new tab there.
struct FolderChip: View {
    /// Nil (or the chat folder): a plain chat, no folder.
    let folder: URL?
    /// Handles a pick (nil = no folder). Without it, a pick opens a new tab there.
    var choose: ((URL?) -> Void)?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            let recents = Recents.all.filter { $0 != current }
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents.prefix(8), id: \.self) { url in
                        Button {
                            pick(url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: "folder")
                        }
                    }
                }
            }
            Button("Choose Folder…") {
                if let url = FolderPanel.run() { pick(url) }
            }
            if current != nil {
                Button("No Folder (Plain Chat)") { pick(nil) }
            }
            if let folder = current {
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: current == nil ? "bubble.left" : "folder")
                Text(current?.lastPathComponent ?? "No folder")
                    .lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .controlSize(.regular)
        .fixedSize()
        .help(current.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "A plain chat, without a project folder. Pick a folder to let kiln work on code.")
    }

    private var current: URL? {
        guard let folder, folder.standardizedFileURL != Kiln.chatFolder.standardizedFileURL else { return nil }
        return folder
    }

    private func pick(_ url: URL?) {
        if let choose { choose(url) } else { openWindow(value: url ?? Kiln.chatFolder) }
    }
}

enum FolderPanel {
    @MainActor
    static func run() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder kiln works in"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// A new conversation before it has a folder: the composer, with the folder chip above it.
/// Nothing starts until a folder is picked; sending without one asks for it first.
struct StartView: View {
    /// Called with the folder (nil for a plain chat) and the first message.
    let start: (URL?, String) -> Void
    @State private var folder: URL?
    @State private var text = ""
    @State private var height: CGFloat = 22
    @State private var controller = ComposerController()
    @State private var skills: [SkillInfo] = []
    @State private var picked = 0

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var skillSuggestions: [SkillInfo] {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        let q = text.dropFirst().lowercased()
        return Array(skills.filter { $0.name.hasPrefix(q) || (!q.isEmpty && $0.name.contains(q)) }.prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "flame")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.orange.gradient)
                Text("What should we work on?")
                    .font(.title2.weight(.semibold))
                Text(folder == nil ? "Chat, or pick a folder to work on code." : "Ask about the code in \(folder!.lastPathComponent), or describe a change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LocalModelCard()
                    .padding(.top, 14)
            }
            Spacer()
            composer
        }
        .onAppear { controller.focus() }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            FolderChip(folder: folder) { folder = $0 }
                .opacity(skillSuggestions.isEmpty ? 1 : 0)
            box
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: 860)
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Ask kiln to do something")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                ComposerTextView(
                    text: $text, height: $height, controller: controller, onSubmit: send, onEscape: { false },
                    onMentionKey: handleKey)
                    .frame(height: height)
            }
            HStack {
                Spacer()
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(!canSend)
                .help("Send (Return)")
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .overlay(alignment: .topLeading) {
            if !skillSuggestions.isEmpty {
                SkillList(skills: skillSuggestions, picked: picked) { controller.replaceAll("/\($0.name) ") }
                    .fixedSize()
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
                    .padding(.leading, 12)
            }
        }
        .task(id: folder) {
            skills = (try? await Kiln.json([SkillInfo].self, args: ["--skills", "--json"], cwd: folder ?? Kiln.chatFolder)) ?? []
        }
        .onChange(of: text) { picked = 0 }
    }

    private func handleKey(_ key: MentionKey) -> Bool {
        let list = skillSuggestions
        guard !list.isEmpty else { return false }
        switch key {
        case .up: picked = (picked - 1 + list.count) % list.count
        case .down: picked = (picked + 1) % list.count
        case .accept: controller.replaceAll("/\(list[min(picked, list.count - 1)].name) ")
        case .cancel: controller.replaceAll("")
        }
        return true
    }

    private func send() {
        guard canSend else { return }
        start(folder, text)
    }
}
