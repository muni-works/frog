import SwiftUI
import UserNotifications

/// The house: where frog on your home server is, and what you've asked it. Siri's "Ask the
/// house" uses these settings; an answer that took longer than Siri waits finishes here.
struct HouseView: View {
    @State private var url = House.url
    @State private var token = House.token
    @State private var model = House.model
    @State private var draft = ""
    @State private var asking = false
    @State private var live = ""
    @State private var log = HouseLog.entries
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                TextField("https://frog.example.com", text: $url)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Token", text: $token)
                TextField("Model (server default)", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Server")
            } footer: {
                Text("frog running with --listen on your home server. Requests go only to this address; the model and the house's tools run there. The token stays in this device's Keychain.")
            }

            Section {
                TextField("Ask the house", text: $draft)
                    .submitLabel(.send)
                    .onSubmit(ask)
                Button(action: ask) {
                    HStack {
                        Label("Ask", systemImage: "house")
                        Spacer()
                        if asking { ProgressView() }
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || asking || url.isEmpty || token.isEmpty)
                if asking, !live.isEmpty {
                    Text(live).foregroundStyle(.secondary)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                }
            } footer: {
                Text("Or say “Ask Frog about the house”, or add Ask the House in Shortcuts.")
            }

            if !log.isEmpty {
                Section("Recent") {
                    ForEach(log) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.request).font(.subheadline.weight(.semibold))
                            if e.pending {
                                Label("Still working", systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
                            }
                            if !e.answer.isEmpty { Text(e.answer).font(.callout) }
                        }
                        .textSelection(.enabled)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("The House")
        .onChange(of: url) { House.url = url.trimmingCharacters(in: .whitespaces) }
        .onChange(of: token) { House.token = token.trimmingCharacters(in: .whitespaces) }
        .onChange(of: model) { House.model = model.trimmingCharacters(in: .whitespaces) }
        .task {
            // So a slow answer can reach you after Siri has moved on.
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await HouseLog.refresh()
            log = HouseLog.entries
        }
    }

    private func ask() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        asking = true
        problem = nil
        live = ""
        Task {
            defer { asking = false }
            do {
                let a = try await House.ask(q) { a in Task { @MainActor in live = a.text } }
                HouseLog.save(q, a.failed.map { "frog couldn't finish: \($0)" } ?? a.text, session: a.session)
                draft = ""
            } catch House.Failure.unreachable {
                HouseLog.save(q, await OnDevice.answer(q), session: nil)
                draft = ""
            } catch House.Failure.refused(let why) {
                problem = why
            } catch {
                problem = error.localizedDescription
            }
            log = HouseLog.entries
        }
    }
}
