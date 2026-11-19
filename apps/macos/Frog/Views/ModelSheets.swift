import AppKit
import SwiftUI

/// The sheets Settings › Models opens (a provider's key, its models, a server of your own),
/// Frog Cloud's key line, and what `frog --mcp --json` says about each MCP server. They were
/// in the tabbed Settings window, which Settings mode replaced (docs/design/app-shell.md).

enum Models {
    /// Everything `frog --models` knows, from the home folder.
    static func load() async -> [ModelEntry] {
        (try? await Frog.json([ModelEntry].self, args: ["--models", "--json"],
                               cwd: FileManager.default.homeDirectoryForCurrentUser)) ?? []
    }
}

/// Which cloud models show in the picker: search every connected provider's catalog and turn
/// models on or off.
struct CatalogSheet: View {
    /// Just this provider's models (nil: every connected provider's).
    var provider: ProviderInfo? = nil
    @State private var store = ProviderStore.shared
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    /// Matches for the search (every word in the name or spec); without one, what's on.
    private var catalog: [CatalogModel] {
        guard let provider else { return store.catalog }
        return store.catalog.filter { $0.provider == provider.id }
    }

    private var matches: [CatalogModel] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return catalog.filter { $0.enabled == true } }
        return catalog.filter { m in
            let hay = (m.name + " " + m.spec).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search \(catalog.count) \(provider?.name ?? "") models", text: $query)
                    .textFieldStyle(.roundedBorder)
                if store.loadingCatalog {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await store.loadCatalog(refresh: true) }
                    }
                    .labelStyle(.iconOnly)
                    .help("Fetch the latest model lists")
                }
            }
            .padding(12)
            Form {
                let list = Array(matches.prefix(150))
                if list.isEmpty {
                    Text(query.isEmpty ? "Search to find models from the providers you've connected, and turn on the ones you want in the picker." : "No models match.")
                        .foregroundStyle(.secondary)
                }
                ForEach(list) { m in
                    CatalogRow(model: m, provider: store.provider(m.provider)) { on in
                        Task { await store.setEnabled(m.spec, on) }
                    }
                }
                if matches.count > list.count {
                    Text("\(matches.count - list.count) more; narrow the search.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
        .task { await store.loadCatalog() }
    }
}

private struct CatalogRow: View {
    let model: CatalogModel
    let provider: ProviderInfo?
    let toggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { model.enabled ?? false }, set: toggle)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(details).font(.frog(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .disabled(!(provider?.connected ?? false) && model.enabled != true)
        .help(provider?.connected == false ? "Add a \(provider?.name ?? "provider") key to use this model" : model.spec) // advanced
    }

    private var details: String {
        var parts = [provider?.name ?? model.provider]
        if let c = model.contextLabel { parts.append("\(c) context") }
        if model.vision { parts.append("sees images") }
        if model.reasoning { parts.append("reasons") }
        if !model.tools { parts.append("no tools") }
        if let p = model.price { parts.append(p) }
        return parts.joined(separator: ", ")
    }
}

/// frog cloud's fixed card in Settings → Models: always there, never removable. Shows the plan
/// and where the key comes from; signed out, offers adding or getting a key.
struct FrogCloudCard: View {
    /// frog cloud as the engine lists it (nil with an engine that doesn't list it yet).
    let provider: ProviderInfo?
    let addKey: (ProviderInfo) -> Void
    @State private var store = ProviderStore.shared

    static let getKeyURL = URL(string: "https://api.frog.toys/beta")!
    @State private var signingIn: Task<Void, Never>?
    /// Why the last sign-in didn't finish (nil once you cancel or retry), and with what.
    @State private var failure: String?
    @State private var lastProvider = "github"

    /// GitHub or Google in the browser, back to this Mac with its own key, saved where frog reads it.
    private func signIn(_ provider: String = "github") {
        failure = nil
        lastProvider = provider
        signingIn = Task {
            defer { signingIn = nil }
            do {
                try await CloudAccount.signInAndSave(provider: provider)
            } catch {
                failure = CloudAccount.signInFailure(error)
            }
        }
    }

    /// Where the key comes from, or nil when there's none. FROG_API_KEY wins over a saved key.
    static func keyLine(_ source: String?) -> String? {
        switch source {
        case "env": "API key, FROG_API_KEY (from your environment; a saved key is ignored here)"
        case "keychain": "API key, Keychain"
        default: nil
        }
    }

    /// The plan badge. A placeholder until the account endpoint says (Pro, API).
    static let plan = "beta"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cloud.fill").foregroundStyle(Color.place(.frogCloud)).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ProviderID.cloudName)
                    Text(Self.plan)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.place(.frogCloud).opacity(0.18), in: .capsule)
                        .foregroundStyle(Color.place(.frogCloud))
                }
                Text(Self.keyLine(provider?.key) ?? "Fast hosted models from frog. Sign in or add a key to use them.")
                    .font(.frog(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure, signingIn == nil {
                    HStack(spacing: 6) {
                        Text(failure).font(.frog(size: 10)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") { signIn(lastProvider) }
                            .controlSize(.mini)
                    }
                }
            }
            Spacer()
            if provider?.key == nil {
                if let task = signingIn {
                    Text("Signing In…").font(.frog(size: 11)).foregroundStyle(.secondary)
                    Button("Cancel") { task.cancel() }
                        .controlSize(.small)
                } else {
                    Menu("Sign In") {
                        Button("Continue with GitHub") { signIn("github") }
                        Button("Continue with Google") { signIn("google") }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                Link("Get a Key", destination: Self.getKeyURL)
                    .controlSize(.small)
                if let provider {
                    Button("Add a Key") { addKey(provider) }
                        .controlSize(.small)
                }
            } else if let provider {
                Menu {
                    Button("Sign In Again with GitHub") { signIn("github") }
                    Button("Sign In Again with Google") { signIn("google") }
                    Button("Change Key…") { addKey(provider) }
                    // Only a saved key can be removed here; an environment key is the shell's.
                    if provider.key == "keychain" {
                        Button("Remove Key", role: .destructive) { Task { await store.setKey("", for: provider.id) } }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

/// Paste a provider's API key; it goes to the Keychain through frog, never to disk.
struct KeySheet: View {
    let provider: ProviderInfo
    @State private var key = ""
    @State private var saving = false
    @State private var store = ProviderStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect \(provider.displayName)").font(.frog(size: 13, weight: .semibold))
            SecureField("API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let url = URL(string: provider.keyUrl), !provider.keyUrl.isEmpty {
                Link("Get a key from \(provider.displayName)", destination: url).font(.frog(size: 12))
            }
            Text("Stored in your Keychain. Frog sends it only to \(provider.displayName).")
                .font(.frog(size: 10))
                .foregroundStyle(.secondary)
            if let e = store.error { Text(e).font(.frog(size: 10)).foregroundStyle(.red) }
            HStack {
                if provider.key == "keychain" {
                    Button("Remove Key", role: .destructive) {
                        Task { await store.setKey("", for: provider.id); dismiss() }
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        saving = true
        Task {
            await store.setKey(key, for: provider.id)
            saving = false
            if store.error == nil { dismiss() }
        }
    }
}

/// Add a server on your network (a GPU box running Ollama, vLLM, llama.cpp or LM Studio).
struct ServerSheet: View {
    let added: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var ollama = true
    @State private var saving = false
    @State private var store = ProviderStore.shared
    @Environment(\.dismiss) private var dismiss

    /// "GPU Box" → "gpu-box".
    private var id: String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return slug.split(separator: "-").joined(separator: "-")
    }

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("GPU Box"))
            Picker("Runs", selection: $ollama) {
                Text("Ollama").tag(true) // advanced
                Text("OpenAI-compatible (vLLM, llama.cpp, LM Studio)").tag(false)
            }
            TextField("URL", text: $url, prompt: Text(ollama ? "http://gpu-box.local:11434" : "http://gpu-box.local:8000/v1"))
            if !id.isEmpty {
                LabeledContent("Models appear as", value: "\(id)/<model>")
                    .foregroundStyle(.secondary)
            }
            if let e = store.error { Text(e).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    saving = true
                    Task {
                        let ok = await store.addServer(id: id, name: name, url: url.trimmingCharacters(in: .whitespaces), ollama: ollama)
                        saving = false
                        if ok { added(); dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(id.isEmpty || url.isEmpty || saving)
            }
            .padding()
        }
        .frame(width: 460, height: 300)
    }
}

struct MCPStatus: Decodable, Identifiable {
    struct Quarantined: Decodable {
        let tool: String
        let reason: String
    }
    let name: String
    let connected: Bool
    let error: String?
    let tools: [String]
    let quarantined: [Quarantined]
    /// The server answered 401 and wants an OAuth sign-in: "Sign in" is the button for it,
    /// and the only thing in frog that opens a browser for MCP. Older engines omit it.
    let needsAuth: Bool?
    /// The person already declined this server's sign-in (remembered across sessions).
    let declined: Bool?
    var id: String { name }
}
