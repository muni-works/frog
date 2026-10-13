import SwiftUI

/// The phone's settings: what the Mac has spent and used, and how the phone behaves. Spending
/// and energy are the Mac's record, as it sent them; the cap is set on the Mac.
struct SettingsSheet: View {
    let remote: Remote
    @Environment(\.dismiss) private var dismiss
    @AppStorage("playfulSounds") private var sounds = true
    private let stats = ModelStats.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("This week", value: ModelStats.spent(stats.spentThisWeek))
                    if stats.monthlyCap > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("This month", value: "\(ModelStats.spent(stats.spentThisMonth)) of \(ModelStats.money(stats.monthlyCap))")
                            ProgressView(value: min(1, stats.spentThisMonth / stats.monthlyCap))
                                .tint(stats.overCap ? .red : .accentColor)
                        }
                    } else {
                        LabeledContent("This month", value: ModelStats.spent(stats.spentThisMonth))
                    }
                } header: {
                    Text("Cloud models")
                } footer: {
                    Text(stats.overCap
                         ? "Cloud models are paused for the rest of the month. Change the cap in frog's settings on your Mac."
                         : "At each provider's list prices. A monthly cap is set in frog's settings on your Mac.")
                }

                Section {
                    NavigationLink {
                        EnergySettings().navigationTitle("Energy")
                    } label: {
                        Label("Energy", systemImage: "leaf")
                    }
                } footer: {
                    Text("What frog's turns used: measured by your Mac's power sensor, plus an estimate for a cloud model's data center.")
                }

                Section {
                    NavigationLink {
                        HouseView()
                    } label: {
                        Label("The House", systemImage: "house")
                    }
                } footer: {
                    Text("frog on your home server, for Siri: “Ask Frog about the house”.")
                }

                Section {
                    Toggle(isOn: $sounds) { Label("Frog sounds", systemImage: "speaker.wave.2") }
                }

                Section {
                    if case .connected(let host) = remote.state {
                        LabeledContent("Connected to", value: host)
                    }
                    Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                        dismiss()
                        remote.disconnect(forget: true)
                    }
                } header: {
                    Text("Your Mac")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}

/// The energy history, from a turn's energy card.
struct EnergyHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EnergySettings()
                .navigationTitle("Energy")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                }
        }
    }
}
