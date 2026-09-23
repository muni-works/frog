import AppKit
import SwiftUI

/// The toolbar's center, like Xcode's activity viewer: one glass capsule that says what kiln is
/// doing right now (or how the last turn went), with the model readout on the right: the model,
/// how full the context is, and generation speed.
struct ActivityViewer: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 10) {
            activity
                .frame(maxWidth: .infinity, alignment: .leading)
            if let s = conversation.status {
                Divider().frame(height: 14)
                readout(s)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(minWidth: 360, idealWidth: 460, maxWidth: 560)
        .frame(height: 30)
        .overlay(alignment: .bottom) {
            if conversation.busy { WorkingLine().padding(.horizontal, 16) }
        }
        .glassEffect(.regular, in: .capsule)
        .animation(.snappy(duration: 0.2), value: conversation.busy)
    }

    // MARK: Left: what's happening

    @ViewBuilder
    private var activity: some View {
        if conversation.busy, let turn = conversation.turns.last, !turn.finished {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 7) {
                    Image(systemName: symbol(turn)).foregroundStyle(.orange).frame(width: 14)
                    Text(live(turn)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(elapsed(turn)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } else if conversation.busy {
            HStack(spacing: 7) {
                Image(systemName: "hourglass").foregroundStyle(.secondary).frame(width: 14)
                Text(conversation.progress.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Starting…")
                    .lineLimit(1)
            }
        } else if let turn = conversation.turns.last, let end = turn.end {
            HStack(spacing: 7) {
                Image(systemName: done(end).symbol).foregroundStyle(done(end).color).frame(width: 14)
                Text(done(end).text).lineLimit(1)
                if let d = duration(turn) {
                    Text(d).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } else {
            HStack(spacing: 7) {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green).frame(width: 14)
                Text("Ready").foregroundStyle(.secondary)
            }
        }
    }

    private func symbol(_ turn: TurnState) -> String {
        guard let last = turn.items.last else { return "sparkles" }
        switch last.kind {
        case .tool(let name, _): return ToolIcon.symbol(name)
        case .reasoning: return "sparkles"
        case .message: return "text.bubble"
        case .notice: return "info.circle"
        }
    }

    private func live(_ turn: TurnState) -> String {
        if conversation.permission != nil { return "Waiting for your permission" }
        guard let last = turn.items.last else { return "Thinking" }
        switch last.kind {
        case .tool("Task", _):
            return "Subagent: \(last.subagent?.activity ?? "Starting")"
        case .tool(let name, let arg):
            let verb = ["Bash": "Running", "Read": "Reading", "Edit": "Editing", "Write": "Writing",
                        "Grep": "Searching", "Glob": "Finding", "Diagram": "Drawing", "CodeMap": "Mapping",
                        "Task": "Delegating", "McpTools": "Finding tools", "Skill": "Loading skill"][name]
                ?? ToolIcon.title(name)
            return arg.isEmpty ? verb : "\(verb) \(arg)"
        case .reasoning: return "Thinking"
        case .message: return "Writing the answer"
        case .notice: return last.text
        }
    }

    private func elapsed(_ turn: TurnState) -> String {
        guard let start = turn.startedAt else { return "" }
        let s = Int(Date.now.timeIntervalSince(start))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    private func duration(_ turn: TurnState) -> String? {
        guard let a = turn.startedAt, let b = turn.endedAt else { return nil }
        let s = Int(b.timeIntervalSince(a))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    private func done(_ end: EndReason) -> (text: String, symbol: String, color: Color) {
        switch end {
        case .complete: ("Finished", "checkmark.circle.fill", .green)
        case .denied: ("Stopped: permission denied", "hand.raised.fill", .orange)
        case .cancelled: ("Interrupted", "stop.circle.fill", .secondary)
        case .maxTokens: ("Hit the output limit", "text.append", .orange)
        case .looping: ("Stopped: repeating itself", "arrow.trianglehead.2.clockwise", .orange)
        case .stepLimit: ("Stopped at the step limit", "flag.checkered", .orange)
        case .error: ("Failed", "exclamationmark.octagon.fill", .red)
        }
    }

    // MARK: Right: the readout

    private func readout(_ s: Status) -> some View {
        HStack(spacing: 8) {
            Text(shortModel(s.model))
                .fontWeight(.medium)
                .lineLimit(1)
                .help("\(s.model) · \(s.toolMode) tool calls · \(s.tier) tier")
            ContextRing(status: s)
            if let tps = s.tokensPerSec, tps > 0 {
                Text("\(Int(tps)) tok/s")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
    }

    private func shortModel(_ spec: String) -> String {
        let name = spec.split(separator: "/").last.map(String.init) ?? spec
        return name.replacingOccurrences(of: "-4bit", with: " 4-bit")
    }
}

/// An indeterminate progress sweep along the bottom edge of the activity viewer.
private struct WorkingLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { ctx in
            GeometryReader { geo in
                let w = geo.size.width
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                let x = reduceMotion ? 0 : (t * 1.4 - 0.2) * w
                Capsule()
                    .fill(LinearGradient(colors: [.clear, .orange.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: reduceMotion ? w : w * 0.3, height: 2)
                    .offset(x: x)
            }
        }
        .frame(height: 2)
        .clipShape(.capsule)
        .allowsHitTesting(false)
    }
}

/// Dock tile progress, like Xcode's: while any window has a turn running, the icon gets a
/// spinning ring; it goes away when everything is idle.
@MainActor
final class DockActivity {
    static let shared = DockActivity()

    private var busy: Set<ObjectIdentifier> = []
    private var timer: Timer?
    private var phase: CGFloat = 0
    private lazy var view = DockTileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))

    func set(_ id: ObjectIdentifier, busy isBusy: Bool) {
        if isBusy { busy.insert(id) } else { busy.remove(id) }
        update()
    }

    private func update() {
        if busy.isEmpty {
            timer?.invalidate()
            timer = nil
            NSApp.dockTile.contentView = nil
            NSApp.dockTile.display()
            return
        }
        guard timer == nil else { return }
        NSApp.dockTile.contentView = view
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.phase = (self.phase + 1 / 24).truncatingRemainder(dividingBy: 1)
                self.view.phase = self.phase
                NSApp.dockTile.display()
            }
        }
    }
}

private final class DockTileView: NSView {
    var phase: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let inset = bounds.insetBy(dx: 10, dy: 10)
        let center = NSPoint(x: inset.midX, y: inset.midY)
        let radius = inset.width / 2
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        NSColor.black.withAlphaComponent(0.25).setStroke()
        track.lineWidth = 7
        track.stroke()
        let arc = NSBezierPath()
        let start = 90 - phase * 360
        arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - 100, clockwise: true)
        NSColor.systemOrange.setStroke()
        arc.lineWidth = 7
        arc.lineCapStyle = .round
        arc.stroke()
    }
}
