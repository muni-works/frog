import SwiftUI

/// Choose the model for a conversation: the Mac's list, in the Mac's sections and rows. The Mac
/// does the choosing (switch, download first, or ask about the cloud), so the phone only asks
/// what the Mac can't decide alone.
struct ModelSheet: View {
    let remote: Remote
    let session: String
    let current: String?
    @Environment(\.models) private var models
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var working: String?
    @State private var askingCloud: (spec: String, project: String, provider: String)?
    @State private var problem: String?
    /// Said once the sheet is gone: "Downloading Qwen3 8B…".
    var onNote: (String) -> Void = { _ in }

    private var sections: [(title: String, models: [ModelIdentity])] {
        var usable = models.map(ModelIdentity.init)
        if let current, !usable.contains(where: { $0.spec == current }) {
            usable.insert(ModelIdentity.of(current, in: models), at: 0)
        }
        let words = query.lowercased().split(separator: " ")
        let match = { (m: ModelIdentity) in words.allSatisfy { (m.name + " " + m.spec).lowercased().contains($0) } }
        return ModelSections.make(usable: usable.filter(match), suggested: [], alwaysFrogCloud: query.isEmpty)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.models, id: \.spec) { m in
                            Button { choose(m.spec) } label: {
                                ModelListRow(model: m, current: m.spec == current) {
                                    if working == m.spec { ProgressView() }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(working != nil)
                        }
                    }
                }
            }
            .overlay {
                if models.isEmpty {
                    ContentUnavailableView("No models yet", systemImage: "cpu",
                                           description: Text("The models frog can use show up once your Mac sends them."))
                }
            }
            .searchable(text: $query, prompt: "Search models")
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .confirmationDialog(askingCloud.map { "Use cloud models in \($0.project)?" } ?? "",
                                isPresented: Binding(get: { askingCloud != nil }, set: { if !$0 { askingCloud = nil } }),
                                titleVisibility: .visible, presenting: askingCloud) { a in
                Button("Just This Conversation") { choose(a.spec, cloud: "once") }
                Button("Always Allow") { choose(a.spec, cloud: "always") }
                Button("Keep It on Your Devices", role: .cancel) {}
            } message: { a in
                Text("It runs at \(a.provider). The files you mention, the commands frog runs and their output are sent there to answer you.")
            }
            .alert("Couldn't switch", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
        }
    }

    private func choose(_ spec: String, cloud: String? = nil) {
        guard spec != current || cloud != nil else { return dismiss() }
        working = spec
        Task {
            let r = await remote.useModel(spec, in: session, cloud: cloud)
            working = nil
            switch r {
            case .success(.switched):
                dismiss()
            case .success(.downloading(let name)):
                onNote("Downloading \(name) on your Mac. frog switches to it when it's ready.")
                dismiss()
            case .success(.askCloud(let project, let provider)):
                askingCloud = (spec, project, provider)
            case .failure(let e):
                problem = e.message
            }
        }
    }
}

/// The current model, in the composer: opens the list.
struct ModelButton: View {
    let identity: ModelIdentity
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                ModelLabel(model: identity, size: .pill)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model: \(identity.spoken)")
    }
}
