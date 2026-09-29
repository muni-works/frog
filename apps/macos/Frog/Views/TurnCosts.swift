import SwiftUI

/// A turn's cost and energy at the end of its footer: quiet text that opens the working behind
/// it, like the context ring does. Shared by the turn footer and anywhere else a turn's usage
/// is shown.
enum TurnCostCopy {
    /// Grams of CO₂e per kWh: the world's average electricity in 2025 (Ember, Global
    /// Electricity Review 2026). frog.eco/energy uses the same.
    static let gridGramsPerKWh = 458.0
    /// A phone battery's worth, about 4,000 mAh at 3.85 V.
    static let phoneWh = 15.0
    /// An LED bulb that replaces a 60 W incandescent.
    static let bulbW = 9.0

    /// "2% of a phone charge", "a third of a phone charge", "3 phone charges".
    static func phone(_ wh: Double) -> String {
        let f = wh / phoneWh
        if f >= 1.5 { return "\(Int(f.rounded())) phone charges" }
        if f >= 0.9 { return "about a phone charge" }
        let pct = f * 100
        return pct < 1 ? "under 1% of a phone charge" : "\(Int(pct.rounded()))% of a phone charge"
    }

    /// "a 9 W LED bulb for 40 seconds" / "… for 2.1 minutes" / "… for 3.4 hours".
    static func bulb(_ wh: Double) -> String {
        let secs = wh / bulbW * 3600
        let t = secs < 90 ? "\(Int(secs.rounded())) seconds" : secs < 5400 ? String(format: "%.1f minutes", secs / 60) : String(format: "%.1f hours", secs / 3600)
        return "a \(Int(bulbW)) W LED bulb for \(t)"
    }

    /// "0.14 g", "<0.01 g", "3.2 g".
    static func grams(_ wh: Double) -> String {
        let g = wh / 1000 * gridGramsPerKWh
        return g < 0.01 ? "<0.01 g" : g < 10 ? String(format: "%.2f g", g) : "\(Int(g.rounded())) g"
    }
}

/// "· 0.4 Wh", clickable: what this Mac spent, what a data center likely did, and what that
/// amounts to.
struct EnergyHint: View {
    let energy: TurnEnergy
    let usage: TurnUsage
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Text(ModelStats.energy(energy.totalWh, estimated: energy.estimated))
                .hoverPlate(h: 4, v: 2)
        }
        .buttonStyle(.plain)
        .help("Energy for this turn")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            EnergyCard(energy: energy, usage: usage)
        }
    }
}

struct EnergyCard: View {
    let energy: TurnEnergy
    let usage: TurnUsage

    private var total: Double { max(energy.totalWh, 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Energy").font(.headline)
                Spacer()
                Text(ModelStats.energy(total, estimated: energy.estimated))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }

            SplitBar(parts: [
                .init(value: energy.localWh, style: .solid),
                .init(value: energy.remoteWh ?? 0, style: .hatched),
            ])

            VStack(alignment: .leading, spacing: 8) {
                PartRow(swatch: .solid, title: "This Mac", value: ModelStats.energy(energy.localWh),
                        detail: energy.idleW.map { "Measured, above the \(String(format: "%.1f", $0)) W it drew at rest" } ?? "Measured")
                if let remote = energy.remoteWh {
                    PartRow(swatch: .hatched, title: "Data center", value: ModelStats.energy(remote, estimated: true),
                            detail: "Estimated from \(usage.inputTokens.tokens) tokens in, \(usage.outputTokens.tokens) out")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Fact(symbol: "leaf", text: "\(TurnCostCopy.grams(total)) of CO₂e on the world's average grid")
                Fact(symbol: "iphone", text: TurnCostCopy.phone(total).capitalizedFirst)
                Fact(symbol: "lightbulb", text: "Or " + TurnCostCopy.bulb(total))
            }

            Divider()

            Text(explainer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: URL(string: "https://frog.eco/energy")!) {
                Label("How it's measured", systemImage: "arrow.up.right")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(16)
        .frame(width: 290)
    }

    private var explainer: String {
        var s = "This Mac's own power sensor, read ten times a second across the turn, less what it drew at rest just before. Anything else running at the time counts too."
        if energy.remoteWh != nil {
            s += " The data center's share is a published per-token estimate for a frontier model on H100s; with prompt caching the real figure is likely lower."
        }
        return s
    }
}

/// "· 11¢", clickable: what went in and out, at what price, and the month so far.
struct PriceHint: View {
    let cost: Double
    let usage: TurnUsage
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Text(ModelStats.money(cost)).hoverPlate(h: 4, v: 2)
        }
        .buttonStyle(.plain)
        .help("Cost of this turn")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            PriceCard(cost: cost, usage: usage)
        }
    }
}

struct PriceCard: View {
    let cost: Double
    let usage: TurnUsage
    /// The model's list price; looked up from what frog has learned when not given.
    var listed: (input: Double, output: Double)?
    private let stats = ModelStats.shared

    private var prices: (input: Double, output: Double)? { listed ?? usage.model.flatMap { stats.prices($0) } }
    private var inCost: Double { prices.map { Double(usage.inputTokens) * $0.input / 1_000_000 } ?? 0 }
    private var outCost: Double { prices.map { Double(usage.outputTokens) * $0.output / 1_000_000 } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cost").font(.headline)
                Spacer()
                Text(ModelStats.money(cost)).font(.headline.monospacedDigit())
            }

            SplitBar(parts: [.init(value: inCost, style: .solid), .init(value: outCost, style: .soft)])

            if let p = prices {
                VStack(alignment: .leading, spacing: 8) {
                    PartRow(swatch: .solid, title: "Reading", value: Self.cents(inCost),
                            detail: "\(usage.inputTokens.tokens) tokens in at \(Self.perMillion(p.input)) per million")
                    PartRow(swatch: .soft, title: "Writing", value: Self.cents(outCost),
                            detail: "\(usage.outputTokens.tokens) tokens out at \(Self.perMillion(p.output)) per million")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if stats.monthlyCap > 0 {
                    HStack(alignment: .firstTextBaseline) {
                        Text("This month")
                        Spacer()
                        Text("\(ModelStats.spent(stats.spentThisMonth)) of \(ModelStats.money(stats.monthlyCap))")
                            .monospacedDigit()
                    }
                    .font(.callout)
                    ProgressView(value: min(1, stats.spentThisMonth / stats.monthlyCap))
                        .tint(stats.overCap ? .red : .accentColor)
                } else {
                    Fact(symbol: "calendar", text: "\(ModelStats.spent(stats.spentThisMonth)) on cloud models this month")
                }
                Fact(symbol: "text.word.spacing", text: "About \(Int((Double(usage.outputTokens) * ModelStats.wordsPerToken).rounded())) words written, \(usage.modelCalls) call\(usage.modelCalls == 1 ? "" : "s")")
            }

            Divider()

            Text("Each call re-reads the whole conversation, so reading usually costs more than writing. Priced at the provider's list rates; cached-input discounts aren't taken off, so the real bill can be lower.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 290)
    }

    /// "4.2¢", "$1.84", "<0.1¢".
    private static func cents(_ d: Double) -> String {
        if d >= 1 { return String(format: "$%.2f", d) }
        let c = d * 100
        return c < 0.1 ? "<0.1¢" : String(format: "%.1f¢", c)
    }

    /// "$15", "$0.60".
    private static func perMillion(_ d: Double) -> String {
        d >= 10 ? "$\(Int(d.rounded()))" : String(format: "$%.2f", d)
    }
}

// MARK: - Pieces

private enum Swatch { case solid, soft, hatched }

/// One bar split into parts, in proportion; estimated parts are hatched.
private struct SplitBar: View {
    struct Part { let value: Double; let style: Swatch }
    let parts: [Part]

    var body: some View {
        let total = max(parts.map(\.value).reduce(0, +), .ulpOfOne)
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    if p.value > 0 {
                        SwatchFill(style: p.style)
                            .frame(width: max(3, (geo.size.width - 2) * p.value / total))
                    }
                }
            }
        }
        .frame(height: 8)
        .clipShape(.capsule)
        .background(Color.primary.opacity(0.06), in: .capsule)
    }
}

private struct SwatchFill: View {
    let style: Swatch

    var body: some View {
        switch style {
        case .solid: Rectangle().fill(Color.accentColor)
        case .soft: Rectangle().fill(Color.accentColor.opacity(0.4))
        case .hatched:
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.accentColor.opacity(0.18)))
                var x = -size.height
                while x < size.width {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: size.height))
                    p.addLine(to: CGPoint(x: x + size.height, y: 0))
                    ctx.stroke(p, with: .color(Color.accentColor), lineWidth: 1.5)
                    x += 4
                }
            }
        }
    }
}

private struct PartRow: View {
    let swatch: Swatch
    let title: String
    let value: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SwatchFill(style: swatch)
                .frame(width: 10, height: 10)
                .clipShape(.rect(cornerRadius: 3))
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                    Spacer()
                    Text(value).monospacedDigit()
                }
                .font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Fact: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
        .font(.callout)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
