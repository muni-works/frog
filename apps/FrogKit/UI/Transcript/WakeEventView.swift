import SwiftUI

/// What opens a turn in the transcript: a user bubble only for what someone typed. A message
/// from another session is its card; background wakes are event rows.
enum TurnLead: Equatable {
    case prompt
    case sessionMessage(SessionMessage)
    case wakes([WakeEvent])
    case none

    init(_ turn: TurnState) {
        if let delivered = SessionMessage.parse(turn.input) {
            self = .sessionMessage(delivered)
        } else if turn.more.isEmpty, turn.images.isEmpty, let wakes = WakeEvent.parse(turn.input) {
            self = .wakes(wakes)
        } else if !turn.input.isEmpty || !turn.more.isEmpty {
            self = .prompt
        } else {
            self = .none
        }
    }
}

/// A turn the engine started on background wakes alone: one compact line per wake (glyph,
/// id, what it was, how it ended, a link to the job's log), on the left like the session
/// message card, never as a user bubble. The model's answer follows as usual.
struct WakeEventRows: View {
    let events: [WakeEvent]
    let jobs: [String: BackgroundJob]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                WakeEventRow(event: event, job: jobs[event.id])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WakeEventRow: View {
    let event: WakeEvent
    let job: BackgroundJob?
    @State private var expanded = false

    /// What the piece was: the job's command, the monitor's check, the timer's note.
    var headline: String {
        if let label = job?.label, !label.isEmpty { return label }
        if event.kind == .timer, !event.body.isEmpty { return event.body }
        return event.kind == .note ? event.body : ""
    }

    private var glyph: String {
        switch event.kind {
        case .job: "terminal"
        case .monitor: "eye"
        case .timer: "alarm"
        case .task: "person.crop.circle.badge.checkmark"
        case .note: "info.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: glyph)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                if !event.id.isEmpty {
                    Text("woke on \(event.id)").fontWeight(.medium)
                }
                if !headline.isEmpty {
                    Text(headline)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !event.outcome.isEmpty {
                    Text(event.outcome)
                        .foregroundStyle(event.failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                if let log = job?.log {
                    Button("log") { Platform.open(URL(fileURLWithPath: log)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .help(log)
                }
                if event.kind != .note, !event.body.isEmpty {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(expanded ? "Hide what the agent was told" : "Show what the agent was told")
                }
            }
            .font(.caption)
            if expanded {
                Text(event.body)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
