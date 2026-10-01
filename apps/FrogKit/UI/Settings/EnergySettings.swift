import Charts
import SwiftUI

/// Settings › Energy: what frog's turns have used, per model, drawn like the Battery pane's
/// charts. This Mac's part is measured; a cloud model's data center part is estimated, per
/// model, with its source. Recorded from turns as they finish (the last ten days).
struct EnergySettings: View {
    @AppStorage(ModelStats.energyKey) private var showEnergy = false
    @State private var days = false
    @State private var model: String?
    /// Injected in snapshot tests, so they never touch the app's own history.
    var stats = ModelStats.shared

    private var buckets: [ModelStats.EnergyBucket] { stats.energyBuckets(days: days, spec: model) }
    private var total: (mac: Double, dataCenter: Double) {
        buckets.reduce((0, 0)) { ($0.0 + $1.mac, $0.1 + $1.dataCenter) }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show energy use at the end of each turn", isOn: $showEnergy)
            }

            Section {
                Picker("Period", selection: $days) {
                    Text("Last 24 Hours").tag(false)
                    Text("Last 10 Days").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ModelStats.energy(total.mac + total.dataCenter, estimated: total.dataCenter > 0))
                            .font(.title2.weight(.semibold).monospacedDigit())
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Model", selection: $model) {
                        Text("All Models").tag(String?.none)
                        ForEach(stats.energyModels, id: \.self) { spec in
                            Text(name(spec)).tag(String?.some(spec))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                chart
                    .frame(height: 170)
                    .padding(.top, 4)

                HStack(spacing: 16) {
                    Legend(hatched: false, text: "This Mac, measured")
                    Legend(hatched: true, text: "Data center, estimated")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("By model") {
                if stats.energyModels.isEmpty {
                    Text("Turns you run with energy measured show up here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(stats.energyModels, id: \.self) { spec in
                        ModelEnergyRow(spec: spec, name: name(spec), days: days, stats: stats)
                    }
                }
            }

            Section {
                Text("This Mac's part comes from its own power sensor, read ten times a second over each turn, less what it drew at rest. A cloud model's data center part is an estimate from the tokens used: open-weight models scale a published estimate by their active parameters; closed models, whose size isn't published, assume a frontier model like GPT-4o.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link("How it's measured, and every bench run", destination: URL(string: "https://frog.eco/energy")!)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        // The session logs are on the Mac; the phone's record comes from it.
        .task { await stats.backfillEnergy() }
        #endif
    }

    private var summary: String {
        let span = days ? "the last 10 days" : "the last 24 hours"
        guard total.mac + total.dataCenter > 0 else { return "Nothing recorded in \(span)" }
        let g = TurnCostCopy.grams(total.mac + total.dataCenter)
        return "In \(span) · \(g) CO₂e · \(TurnCostCopy.phone(total.mac + total.dataCenter))"
    }

    private var chart: some View {
        Chart {
            ForEach(buckets) { b in
                BarMark(x: .value("Time", b.start, unit: days ? .day : .hour),
                        y: .value("Wh", b.mac))
                    .foregroundStyle(Color.accentColor)
                BarMark(x: .value("Time", b.start, unit: days ? .day : .hour),
                        y: .value("Wh", b.dataCenter))
                    .foregroundStyle(Color.accentColor.opacity(0.35))
            }
        }
        .chartXScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .stride(by: days ? .day : .hour, count: days ? 1 : 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel(format: days ? .dateTime.weekday(.narrow) : .dateTime.hour(.defaultDigits(amPM: .narrow)))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let wh = v.as(Double.self) { Text(wh == 0 ? "0" : ModelStats.energy(wh)) }
                }
            }
        }
    }

    private var domain: ClosedRange<Date> {
        let cal = Calendar.current
        let now = Date.now
        if days {
            let start = cal.startOfDay(for: now.addingTimeInterval(-9 * 86_400))
            return start...cal.startOfDay(for: now).addingTimeInterval(86_400)
        }
        let end = cal.dateInterval(of: .hour, for: now)!.end
        return end.addingTimeInterval(-24 * 3600)...end
    }

    private func name(_ spec: String) -> String { ModelIdentity.of(spec, in: []).name }
}

/// A model's line: how much, how many Wh a turn, and where its numbers come from.
private struct ModelEnergyRow: View {
    let spec: String
    let name: String
    let days: Bool
    let stats: ModelStats

    var body: some View {
        let b = stats.energyBuckets(days: days, spec: spec)
        let mac = b.map(\.mac).reduce(0, +), dc = b.map(\.dataCenter).reduce(0, +)
        let identity = ModelIdentity.of(spec, in: [])
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label(name, systemImage: identity.place.symbol)
                Spacer()
                Text(ModelStats.energy(mac + dc, estimated: dc > 0)).monospacedDigit()
            }
            .font(.callout)
            if let e = stats.estimate(spec) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(e.basis + ".").foregroundStyle(.secondary)
                    if let url = e.source {
                        Link(url.host()?.replacingOccurrences(of: "www.", with: "") ?? "Source", destination: url)
                    }
                }
                .font(.caption)
            } else {
                Text(dc > 0 ? "Estimated" : "Measured on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct Legend: View {
    let hatched: Bool
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(hatched ? 0.35 : 1))
                .frame(width: 10, height: 10)
            Text(text)
        }
    }
}
