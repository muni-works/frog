import SwiftUI

/// Preview-only Pond concept. Deliberately uses local fake data and has no engine side effects.
struct PondMock: View {
    @State private var expanded: Set<String> = ["infra"]

    private let leads = [
        Lead(id: "infra", name: "Infra", now: "tracing auth timeout", workers: [
            Worker(name: "reproduce timeout", state: .running),
            Worker(name: "add request tracing", state: .waiting)
        ], pr: "#42 · CI 5/5 · Merge", spend: "$12.40 / $25 today", state: .running),
        Lead(id: "macos", name: "macOS", now: "signing fix verified", workers: [],
             pr: "#87 · CI running", spend: "$3.10 / $10 today", state: .running),
        Lead(id: "release", name: "Release", now: "waiting for direction", workers: [
            Worker(name: "draft release notes", state: .idle)
        ], pr: nil, spend: "$0.80 / $8 today", state: .waiting)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("POND").font(.caption.weight(.bold)).tracking(1.2)
                Spacer()
                Button {} label: { Label("lead", systemImage: "plus") }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 8) {
                Text("NEEDS YOU").font(.caption2.weight(.bold)).tracking(0.8)
                attentionRow("Review deploy plan", owner: "Infra")
                attentionRow("$8.20 cap request", owner: "Models")
            }
            .padding(12)
            .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 8).padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(leads) { lead in leadRow(lead) }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(width: 270, height: 470)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func attentionRow(_ title: String, owner: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap").font(.caption2)
            Text(title).lineLimit(1)
            Spacer(minLength: 2)
            Text(owner).foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func leadRow(_ lead: Lead) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(lead.state.color).frame(width: 7, height: 7)
                Text(lead.name).font(.callout.weight(.medium))
                Spacer(minLength: 3)
                Button {
                    if expanded.contains(lead.id) { expanded.remove(lead.id) }
                    else { expanded.insert(lead.id) }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(lead.workers.count) workers")
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded.contains(lead.id) ? 90 : 0))
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            Text("now: \(lead.now)")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).padding(.leading, 15).padding(.top, 2)

            if expanded.contains(lead.id) {
                ForEach(lead.workers) { worker in
                    HStack(spacing: 7) {
                        Circle().fill(worker.state.color).frame(width: 5, height: 5)
                        Text(worker.name).lineLimit(1)
                        Spacer()
                    }
                    .font(.caption).padding(.leading, 25).padding(.top, 7)
                }
            }
            if let pr = lead.pr {
                HStack {
                    Image(systemName: "arrow.triangle.pull")
                    Text(pr).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.leading, 15).padding(.top, 7)
            }
            Text(lead.spend)
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .padding(.leading, 15).padding(.top, 3).padding(.bottom, 7)
        }
        .padding(.horizontal, 8).padding(.top, 9)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private struct Lead: Identifiable {
        let id: String
        let name: String
        let now: String
        let workers: [Worker]
        let pr: String?
        let spend: String
        let state: StateLight
    }

    private struct Worker: Identifiable {
        var id: String { name }
        let name: String
        let state: StateLight
    }

    private enum StateLight {
        case running, waiting, idle
        var color: Color {
            switch self {
            case .running: .green
            case .waiting: .blue
            case .idle: .gray.opacity(0.55)
            }
        }
    }
}

#Preview("Pond sidebar") {
    PondMock()
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}
