import SwiftUI

/// Start something new on the Mac from the phone: what frog should do, and where (a plain chat,
/// or one of your projects). Opens the conversation once the Mac has it going.
struct NewConversationSheet: View {
    let remote: Remote
    let opened: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    /// A conversation whose folder to start in; nil for a chat.
    @State private var like: String?
    @State private var sending = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    /// One conversation per project folder, most recent first, to borrow its folder.
    private var places: [RemoteSession] {
        var seen = Set<String>()
        return remote.sessions.filter { s in
            guard !s.chat, let f = s.folder else { return false }
            return seen.insert(f).inserted
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should frog do?", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                }
                Section("Where") {
                    Picker("Where", selection: $like) {
                        Label("A chat", systemImage: "bubble.left").tag(String?.none)
                        ForEach(places) { s in
                            Label(s.folder ?? s.title, systemImage: "folder").tag(Optional(s.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                }
            }
            .navigationTitle("New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Start") { Task { await start() } }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func start() async {
        sending = true
        failure = nil
        switch await remote.startNew(text.trimmingCharacters(in: .whitespacesAndNewlines), like: like) {
        case .success(let id):
            FrogSounds.shared.play(.plip)
            dismiss()
            opened(id)
        case .failure(let e):
            failure = e.message
        }
        sending = false
    }
}
