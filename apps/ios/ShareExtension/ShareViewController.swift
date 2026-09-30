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
                if let url = item as? URL, let data = try? Data(contentsOf: url) { image = UIImage(data: data) }
                else if let data = item as? Data { image = UIImage(data: data) }
                else if let img = item as? UIImage { image = img }
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
        if let image, let jpeg = image.shrunk(to: 1600).jpegData(compressionQuality: 0.8) {
            op["images"] = [["mime": "image/jpeg", "data": jpeg.base64EncodedString()]]
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

extension UIImage {
    /// At most `side` points on the long edge: enough for a model to read, small enough to send.
    func shrunk(to side: CGFloat) -> UIImage {
        let scale = min(1, side / max(size.width, size.height))
        guard scale < 1 else { return self }
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}
