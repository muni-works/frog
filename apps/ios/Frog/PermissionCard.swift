import SwiftUI

/// Frog asking before it acts, on glass above the keyboard so it can't scroll away. The change
/// or command is right there, so "Allow" is an informed tap.
struct PermissionCard: View {
    let request: PermissionRequest
    let answer: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                FrogFace(mood: .waiting, size: 26).tint(.frog)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    if let reason = request.reason, !reason.isEmpty {
                        Text(reason).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if let diff = request.preview {
                DiffCard(diff: diff, limit: 12)
            } else if !request.arg.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(request.name == "Bash" ? "$ " + request.arg : request.arg)
                        .font(.callout.monospaced())
                        .lineLimit(6)
                        .padding(12)
                }
                .background(Color(.secondarySystemBackground).opacity(0.7), in: .rect(cornerRadius: 14))
            }
            HStack(spacing: 10) {
                Button { answer(.deny) } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button { answer(.allow) } label: {
                    Text("Allow").fontWeight(.semibold).foregroundStyle(.white).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                // The mark's deeper green in both appearances, so white reads on it.
                .tint(Color(red: 0.18, green: 0.62, blue: 0.31))
            }
            .controlSize(.large)
            if !request.always.isEmpty {
                Button { answer(.allowAlways) } label: {
                    Text("Always allow \(request.always)")
                        .font(.footnote)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .tint(.secondary)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .sensoryFeedback(.warning, trigger: request.id)
    }

    private var title: String {
        switch request.name {
        case "Bash": "Run this command?"
        case "Edit": "Edit \((request.arg as NSString).lastPathComponent)?"
        case "Write": "Write \((request.arg as NSString).lastPathComponent)?"
        default: "Use \(request.name)?"
        }
    }
}
