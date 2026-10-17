import Charts
import SwiftUI

// MARK: - Ask

/// The model asking the user to choose. One pick answers right away; with `multi`, picks
/// toggle and Answer sends them. The user can also type their own answer, or skip.
struct QuestionCard: View {
    let question: Question
    let conversation: Conversation
    @State private var picked: Set<String> = []
    @State private var other = ""
    @FocusState private var typing: Bool

    private var multi: Bool { question.multi ?? false }
    private var allowOther: Bool { question.allowOther ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.blue)
                Text(question.question)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.element.label) { i, o in
                    option(o, index: i)
                }
            }
            if allowOther {
                TextField("Something else…", text: $other, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($typing)
                    .onSubmit(send)
            }
            HStack(spacing: 8) {
                if multi || !other.isEmpty {
                    Button(action: send) {
                        Text("Answer").frame(minWidth: 56)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(picked.isEmpty && other.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Answer (⌘↩)")
                }
                Spacer()
                Button("Skip") { conversation.answer(question: []) }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Let frog decide (esc)")
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(.blue.opacity(0.10)), in: .rect(cornerRadius: 14))
    }

    private func option(_ o: Question.Option, index: Int) -> some View {
        let on = picked.contains(o.label)
        return Button {
            if multi {
                if on { picked.remove(o.label) } else { picked.insert(o.label) }
            } else {
                // A pick answers on its own; a half-typed draft isn't part of it.
                conversation.answer(question: [o.label])
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if multi {
                    Image(systemName: on ? "checkmark.square.fill" : "square")
                        .foregroundStyle(on ? Color.accentColor : .secondary)
                } else {
                    Text("\(index + 1)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.label).fontWeight(.medium)
                    if let d = o.detail, !d.isEmpty {
                        Text(d).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(.rect)
            .background(on ? Color.accentColor.opacity(0.12) : Color.clear, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: on ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(index < 9 && !typing ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: []) : nil)
    }

    private func send() {
        let picks = question.options.map(\.label).filter(picked.contains)
        conversation.answer(question: picks, other: other)
    }
}

// MARK: - Present

/// Present's blocks, drawn natively: tables, side-by-side comparisons, steps, callouts and
/// diagrams.
struct PresentCard: View {
    let present: Present
    /// Presses on actions buttons; nil where there's nobody to press them (the buttons are hidden).
    var act: ((Present.Choice) -> Void)?
    @State private var pressed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let t = present.title, !t.isEmpty {
                Text(t).font(.headline)
            }
            ForEach(Array(present.blocks.enumerated()), id: \.offset) { _, b in
                block(b)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func block(_ b: Present.Block) -> some View {
        switch b {
        case .table(let columns, let rows):
            PresentTable(columns: columns, rows: rows)
        case .compare(let left, let right):
            HStack(alignment: .top, spacing: 10) {
                side(left)
                side(right)
            }
        case .steps(let items, let current):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        stepMark(i, current: current)
                        Text(s)
                            .foregroundStyle(current.map { i > $0 } ?? false ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .callout(let tone, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon(tone)).foregroundStyle(color(tone))
                Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color(tone).opacity(0.10), in: .rect(cornerRadius: 10))
        case .diagram(let d):
            DiagramCard(diagram: d)
        case .chart(let kind, let labels, let series, let unit):
            PresentChart(kind: kind, labels: labels, series: series, unit: unit)
        case .stats(let items):
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10, alignment: .topLeading)], alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.label).font(.caption).foregroundStyle(.secondary)
                        Text(s.value).font(.title2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(s.tone.map(color) ?? .primary)
                        if let d = s.detail, !d.isEmpty {
                            Text(d).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 12))
                }
            }
        case .actions(let prompt, let options):
            if let act {
                VStack(alignment: .leading, spacing: 8) {
                    if let p = prompt, !p.isEmpty {
                        Text(p).foregroundStyle(.secondary)
                    }
                    FlowButtons(options: options, pressed: pressed) { o in
                        pressed = o.label
                        act(o)
                    }
                }
            }
        case .unknown:
            EmptyView()
        }
    }

    private func side(_ s: Present.Side) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(s.label).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            Text(s.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 0.5))
    }

    @ViewBuilder
    private func stepMark(_ i: Int, current: Int?) -> some View {
        if let c = current, i < c {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if let c = current, i == c {
            Image(systemName: "circle.dotted").foregroundStyle(.blue).symbolEffect(.pulse)
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    private func icon(_ t: Present.Tone) -> String {
        switch t {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        }
    }

    private func color(_ t: Present.Tone) -> Color {
        switch t {
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .danger: .red
        }
    }
}

/// Actions as a wrapping row of buttons; once one is pressed the rest go quiet.
private struct FlowButtons: View {
    let options: [Present.Choice]
    let pressed: String?
    let press: (Present.Choice) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(Array(options.enumerated()), id: \.offset) { _, o in
            Button {
                press(o)
            } label: {
                Text(o.label).padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .tint(pressed == o.label ? .accentColor : nil)
            .disabled(pressed != nil)
        }
    }
}

private struct PresentChart: View {
    let kind: Present.ChartKind
    let labels: [String]
    let series: [Present.Series]
    let unit: String?

    private struct Point: Identifiable {
        let id: Int
        let label: String
        let series: String
        let value: Double
    }

    private var points: [Point] {
        series.enumerated().flatMap { s, ser in
            zip(labels, ser.values).enumerated().map { i, lv in
                Point(id: s * 1000 + i, label: lv.0, series: ser.name ?? "", value: lv.1)
            }
        }
    }

    var body: some View {
        Chart(points) { p in
            switch kind {
            case .bar:
                BarMark(x: .value("label", p.label), y: .value(unit ?? "value", p.value))
                    .foregroundStyle(by: .value("series", p.series))
                    .position(by: .value("series", p.series))
            case .line:
                LineMark(x: .value("label", p.label), y: .value(unit ?? "value", p.value))
                    .foregroundStyle(by: .value("series", p.series))
                    .symbol(by: .value("series", p.series))
            }
        }
        .chartLegend(series.count > 1 ? .visible : .hidden)
        .chartYAxisLabel(unit ?? "")
        .frame(height: 180)
        .padding(12)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 12))
    }
}

private struct PresentTable: View {
    let columns: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, c in
                        Text(c).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    GridRow {
                        ForEach(Array(r.enumerated()), id: \.offset) { _, cell in
                            Text(cell).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 0.5))
    }
}
