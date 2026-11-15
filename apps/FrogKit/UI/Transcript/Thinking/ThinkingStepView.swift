import SwiftUI

/// One step of a thinking trace. Done, it collapses to one 12 pt line — "✓ **Title** · short
/// result" — regardless of whether the trace is expanded. Live, it shows the thought being
/// written: 12.5 pt secondary text where self-talk beats ("Hmm", "Wait", "Actually", "Hold on")
/// are their own dimmer paragraphs, code sits in compact rounded blocks, options weighed render
/// as pills, and a commitment sentence renders in a green-tinted DECIDED box.
struct ThinkingStepView: View {
    let step: ThinkingStep
    /// This is the step running now.
    var live: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if step.done {
                doneLine
            } else if live {
                liveStep
            } else {
                // A step that finished while the trace was open folds to its line.
                doneLine
            }
            if open, step.kind == .thought, !step.done {
                ThoughtText(text: step.text, live: false)
            }
        }
    }

    /// "✓ Title · short result", clickable when there's a thought to open.
    private var doneLine: some View {
        return Group {
            if clickable {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { open.toggle() }
                } label: { label }
                .buttonStyle(.plain)
                #if os(macOS)
                .pointerStyle(.link)
                #endif
            } else {
                label
            }
        }
    }

    private var clickable: Bool { step.kind == .thought && !step.text.isEmpty }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "checkmark")
                .font(.frog(size: 9, weight: .bold))
                .foregroundStyle(Color.frog.opacity(0.8))
            Text(.init(stepTitleMarkdown))
                .font(.frog(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if clickable {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.frog(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
    }

    private var stepTitleMarkdown: String {
        let title = step.title
        let result = shortResult
        return result.isEmpty ? "**✓ \(title)**" : "**✓ \(title)** · \(result)"
    }

    /// A short result for the done line: the thought's first sentence, or a tool result summary.
    private var shortResult: String {
        switch step.kind {
        case .thought:
            let sentence = firstSentence(step.text)
            return sentence.count > 80 ? "" : sentence
        case .tools:
            return ""
        }
    }

    /// The step as it runs: its thought streamed with beats, code and callouts, or its tool
    /// calls' live progress.
    @ViewBuilder
    private var liveStep: some View {
        switch step.kind {
        case .thought:
            ThoughtText(text: step.text, live: true)
        case .tools:
            ForEach(step.items) { item in
                if case .tool(let name, let arg) = item.kind {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(ActivityWords.now(item))
                            .font(.frog(size: 12.5))
                            .foregroundStyle(.secondary)
                        if !arg.isEmpty {
                            Text(arg)
                                .font(.frog(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .id(item.id)
                    .transition(.opacity)
                }
            }
        }
    }

    private func firstSentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = t.firstIndex { ".!?\n".contains($0) } ?? t.endIndex
        return String(t[..<cut]).trimmingCharacters(in: .whitespaces)
    }
}

/// A thought's text, streamed: paragraphs where self-talk beats are set apart and dimmer, code
/// fences as compact rounded blocks, `inline code` as small chips, and commitment sentences in
/// green-tinted DECIDED boxes.
struct ThoughtText: View {
    let text: String
    /// The thought is still streaming (a caret on the last paragraph, no trailing fades).
    var live: Bool

    /// The words that make a sentence a beat.
    private static let beats = ["Hmm", "Hmm,", "Wait", "Actually", "Hold on", "Wait,"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { i, para in
                paragraph(para, last: i == paragraphs.count - 1)
            }
        }
        .font(.frog(size: 12.5))
        .lineSpacing(12.5 * 0.75)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func paragraph(_ para: Paragraph, last: Bool) -> some View {
        switch para {
        case .fence(let lang, let code):
            ThinkingCodeBlock(language: lang, code: code)
        case .decided(let sentence):
            DecidedCallout(sentence: sentence)
        case .beat(let sentence):
            Text(.init(sentence))
                .foregroundStyle(.tertiary)
                .padding(.top, last ? 0 : 2)
        case .text(let sentence):
            Text(.init(sentence))
        }
    }

    private var paragraphs: [Paragraph] {
        var out: [Paragraph] = []
        var fence: (String, [String])?
        var fenceLang = ""
        var buffer: [String] = []
        func flush() {
            let block = buffer.joined(separator: " ")
            buffer = []
            guard !block.isEmpty else { return }
            for sentence in sentences(in: block) {
                let t = sentence.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                if t == sentence { /* full sentence */ }
                if isDecided(t) { out.append(.decided(t)) }
                else if isBeat(t) { out.append(.beat(t)) }
                else { out.append(.text(t)) }
            }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if l.hasPrefix("```") {
                if let (lang, code) = fence {
                    out.append(.fence(lang, code.joined(separator: "\n")))
                    fence = nil
                } else {
                    flush()
                    fenceLang = String(l.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    fence = (fenceLang, [])
                }
                continue
            }
            if fence != nil {
                fence!.1.append(l)
            } else {
                buffer.append(l)
            }
        }
        if let (lang, code) = fence { out.append(.fence(lang, code.joined(separator: "\n"))) }
        flush()
        return out
    }

    private enum Paragraph {
        case fence(String, String)
        case decided(String)
        case beat(String)
        case text(String)
    }

    /// Splits on sentence enders, keeping the punctuation.
    private func sentences(in block: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in block {
            current.append(ch)
            if ".!?".contains(ch) {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private func isBeat(_ s: String) -> Bool {
        Self.beats.contains { s.hasPrefix($0) }
    }

    private func isDecided(_ s: String) -> Bool {
        ThinkingTraceView.decidedMarkers.contains { s.hasPrefix($0) }
    }
}

/// A compact rounded code block for thinking text: 11.5 pt mono, light syntax colours.
struct ThinkingCodeBlock: View {
    let language: String
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(Highlight.block(code, Highlight.lang(fence: language)))
                .font(.frog(size: 11.5, design: .monospaced))
                .padding(8)
                .fixedSize(horizontal: true, vertical: true)
        }
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 0.5))
    }
}

/// A commitment sentence, in a green-tinted box labelled DECIDED.
struct DecidedCallout: View {
    let sentence: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("DECIDED")
                .font(.frog(size: 8.5, weight: .heavy))
                .foregroundStyle(Color.frog)
            Text(.init(sentence.replacingOccurrences(of: "**", with: "")))
                .font(.frog(size: 12.5))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.frog.opacity(0.10), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.frog.opacity(0.35), lineWidth: 0.5))
    }
}

/// Options weighed (display only, phase 1): when a thought lists alternatives and picks one,
/// rejected ones are struck through and dim, the chosen one is green with a checkmark.
struct OptionPills: View {
    let options: [WeighedOption]

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(options) { option in
                HStack(spacing: 4) {
                    if option.chosen { Image(systemName: "checkmark").font(.frog(size: 8, weight: .bold)) }
                    Text(option.text)
                        .strikethrough(!option.chosen)
                }
                .font(.frog(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(option.chosen ? Color.frog.opacity(0.16) : Color.secondary.opacity(0.1), in: .capsule)
                .foregroundStyle(option.chosen ? Color.frog : Color.secondary)
            }
        }
    }
}

struct WeighedOption: Identifiable {
    let text: String
    var chosen = false
    var id: String { text }
}
