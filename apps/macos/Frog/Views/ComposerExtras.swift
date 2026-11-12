import AppKit
import SwiftUI

/// Above the tray: the one-line toasts and strips that belong to the conversation, not the
/// composer (a toast, the cloud fallback, a model download, what flushes next, the queue, an
/// outward next step).
struct ComposerNotices: View {
    let workspace: Workspace
    let conversation: Conversation
    let downloads: ModelDownloads

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let toast = conversation.toast {
                Label(toast, systemImage: "info.circle")
                    .font(.frog(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .id(toast)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let fallback = conversation.fallbackNotice {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Frog cloud is unavailable").font(.callout.weight(.semibold))
                        Text(fallback).font(.frog(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    Button { conversation.dismissFallbackNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Dismiss")
                }
                .padding(10)
                .background(.orange.opacity(0.09), in: .rect(cornerRadius: 10, style: .continuous))
            }
            if let model = workspace.pendingDownloadModel {
                ModelDownloadStatus(model: model, downloads: downloads) { workspace.useWhenReady(model) }
            }
            let pending = PendingEvents(queued: conversation.queuedEvents, messages: conversation.pendingMessages, jobs: conversation.jobs)
            if !pending.isEmpty {
                PendingEventsStrip(pending: pending, busy: conversation.busy) { conversation.dismissWakes() }
            }
            if !conversation.queue.isEmpty { QueuedMessages(conversation: conversation) }
            if let next = conversation.next, next.act, !conversation.busy {
                Button { conversation.act(Present.Choice(label: next.text, send: nil)) } label: {
                    Label(next.text, systemImage: "arrow.up.forward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .animation(.snappy, value: conversation.toast)
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
                                Text("project").font(.frog(size: 10)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.quaternary, in: .capsule)
                            }
                        }
                        Text(skill.description)
                            .font(.frog(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 22)
                    }
                    .font(.frog(size: 12))
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
                    .font(.frog(size: 12))
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

/// The composer owns the pause between selecting a local model and its snapshot becoming usable.
/// Keeping this here makes the reason Send is disabled visible where someone is trying to send.
struct ModelDownloadStatus: View {
    let model: ModelIdentity
    let downloads: ModelDownloads
    let retry: () -> Void

    var body: some View {
        // Reads the observable state so progress redraws even though `model` is rebuilt by
        // Workspace on each update.
        let state = model.repo.flatMap { downloads.states[$0] }
        switch state {
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(maxWidth: 150)
                Text("Downloading \(model.name) · \(Self.size(fraction, of: model.downloadGB))")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button { if let repo = model.repo { downloads.cancel(repo) } } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop downloading")
            }
            .foregroundStyle(.secondary)
        case .failed(let error):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't download \(model.name): \(error)").lineLimit(1)
                Spacer(minLength: 0)
                Button("Retry", action: retry)
                    .controlSize(.small)
            }
            .font(.frog(size: 12))
        case nil:
            HStack(spacing: 8) {
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                Text("Download paused for \(model.name). Messages send when it’s ready.")
                Spacer(minLength: 0)
                Button("Resume", action: retry).controlSize(.small)
            }
            .font(.frog(size: 12))
        default:
            EmptyView()
        }
    }

    private static func size(_ fraction: Double, of total: Double?) -> String {
        guard let total else { return "\(Int((fraction * 100).rounded()))%" }
        return String(format: "%.1f GB of %.1f GB", fraction * total, total)
    }
}

/// One line when another session swapped the model on the machine this one runs on:
/// "mew switched to Qwen3-8B". Click to dismiss.
struct SwitchNotice: View {
    let conversation: Conversation
    @State private var devices = Devices.shared

    var body: some View {
        if let s = devices.lastSwitch, s.by != conversation.sessionID, ranHere(s.deviceID) {
            Button { devices.dismissSwitch() } label: {
                Label(s.line, systemImage: "arrow.triangle.2.circlepath")
                    .lineLimit(1)
                    .foregroundStyle(Tokens.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Another session swapped the model on this machine. Click to dismiss.")
        }
    }

    private func ranHere(_ deviceID: String) -> Bool {
        guard let status = conversation.status else { return false }
        return devices.serving(model: status.model, ranOn: status.ranOn).deviceID == deviceID
    }
}
