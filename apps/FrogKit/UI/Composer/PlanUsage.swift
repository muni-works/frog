import SwiftUI

/// The plan's allowance windows, as the web's ring popover shows them, and the credit that
/// pays once they run out. Nothing when there's no Frog Cloud key.
struct PlanUsage: View {
    @State private var account = CloudAccount.shared

    var body: some View {
        Group {
            if let me = account.me {
                VStack(alignment: .leading, spacing: 8) {
                    if let sub = me.subscription {
                        HStack {
                            Text(sub.name).font(.frog(size: 13, weight: .semibold))
                            Spacer()
                            Text(sub.over ? "Past allowance · on credit" : "Included allowance")
                                .font(.frog(size: 11)).foregroundStyle(sub.over ? .orange : .secondary)
                        }
                        ForEach(sub.windows, id: \.self) { WindowBar(window: $0) }
                    }
                    HStack {
                        Text("Credit").font(.frog(size: 12))
                        Spacer()
                        Text(CloudFormat.dollars(me.credit_cents)).font(.frog(size: 12).monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .task { await account.refresh() }
    }
}

struct WindowBar: View {
    let window: CloudAccount.Window

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                Spacer()
                Text("\(Int(window.fraction * 100))%" + (window.resets.map { " · resets " + CloudFormat.reset($0, weekly: window.kind != "5h") } ?? ""))
                    .foregroundStyle(.secondary)
            }
            .font(.frog(size: 12))
            ProgressView(value: window.fraction).tint(window.fraction > 0.9 ? .orange : .accentColor)
        }
    }
}

enum CloudFormat {
    static func dollars(_ cents: Double) -> String { Dollars.format(cents / 100) }

    static func reset(_ d: Date, weekly: Bool) -> String {
        weekly ? d.formatted(.dateTime.weekday(.abbreviated)) : d.formatted(date: .omitted, time: .shortened)
    }
}
