import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Send to frog" in the share sheet: a crash screenshot, a log, a link, straight into a
/// conversation that's open on your Mac, with a note.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let host = UIHostingController(rootView: ShareSheet(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        })
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
    }
}

struct ShareSheet: View {
    let providers: [NSItemProvider]
    let done: () -> Void
    let cancel: () -> Void

    @State private var note = ""
    @State private var shared = ""
    @State private var image: UIImage?
    /// The image as it's sent: sized and encoded as a drop on the Mac would be.
    @State private var attachment: ToolImage?
    @State private var target: String?
    @State private var sending = false
    @State private var sent = false
    @State private var failure: String?

    private var conversations: [Snapshot.Row] { (Snapshot.load()?.rows ?? []).filter(\.open) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 10))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Add a note for frog", text: $note, axis: .vertical).lineLimit(2...5)
                            if !shared.isEmpty {
                                Text(shared).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(4)
                            }
                        }
                    }
                }
                Section("Send to") {
                    if conversations.isEmpty {
                        Text("Open a conversation on your Mac, then share again.").foregroundStyle(.secondary)
                    }
                    ForEach(conversations) { c in
                        Button { target = c.id } label: {
                            HStack {
                                Circle().fill(Color.place(cloud: !c.local)).frame(width: 8, height: 8)
                                Text(c.title).foregroundStyle(.primary).lineLimit(1)
                                Spacer()
                                if target == c.id { Image(systemName: "checkmark").foregroundStyle(Color.frog) }
                            }
                        }
                    }
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                }
            }
            .navigationTitle("Send to frog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        FrogFace(mood: sent ? .done : sending ? .working : .idle, size: 20).tint(.frog)
                        Text("Send to frog").font(.headline)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sent ? "Sent" : "Send") { Task { await send() } }
                        .disabled(target == nil || sending || sent)
                }
            }
        }
        .task { await load() }
        .onAppear { target = conversations.first?.id }
        .sensoryFeedback(.success, trigger: sent)
    }

    private func load() async {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let item = try? await p.loadItem(forTypeIdentifier: UTType.image.identifier) {
                let data: Data? = if let url = item as? URL { try? Data(contentsOf: url) }
                    else if let data = item as? Data { data }
                    else { (item as? UIImage)?.jpegData(compressionQuality: 1) }
                if let data {
                    image = UIImage(data: data)
                    attachment = Attachments.image(from: data)
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                shared = url.absoluteString
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                shared = text
            }
        }
    }

    private func send() async {
        guard let target else { return }
        sending = true
        failure = nil
        var text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !shared.isEmpty { text += (text.isEmpty ? "" : "\n\n") + shared }
        var op: [String: Any] = ["op": "submit", "text": text]
        if let attachment {
            op["images"] = [["mime": attachment.mime, "data": attachment.data]]
        }
        do {
            try await QuickLink.send(op, to: target)
            sent = true
            try? await Task.sleep(for: .milliseconds(600))
            done()
        } catch QuickLink.Failure.notPaired {
            failure = "Open frog and connect to your Mac first."
        } catch {
            failure = "Couldn't reach frog on your Mac."
        }
        sending = false
    }
}
