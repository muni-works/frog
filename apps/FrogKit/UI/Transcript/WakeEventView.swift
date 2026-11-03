import SwiftUI

/// What opens a turn in the transcript: event rows for the background wakes it was delivered
/// with (or started on), then a user bubble only for what someone typed, or a card per
/// message from another session.
struct TurnLead: Equatable {
    enum Opener: Equatable {
        case prompt
        case sessionMessages([SessionMessage])
        case none
    }

    var wakes: [WakeEvent]
    var opener: Opener

    init(_ turn: TurnState) {
        wakes = turn.wakes.flatMap { WakeEvent.parse($0) ?? [WakeEvent(kind: .note, id: "", attributes: [], body: $0)] }
        var input = turn.input
        if turn.images.isEmpty, let started = WakeEvent.parse(input) {
            wakes += started
            input = ""
        } else if turn.images.isEmpty, Self.isEngineNote(input) {
            // The engine's own words (a resume, background work lost to a restart), not yours:
            // a notice line, never a user bubble.
            wakes.append(WakeEvent(kind: .note, id: "", attributes: [], body: input))
            input = ""
        }
        let texts = (input.isEmpty ? [] : [input]) + turn.more.map(\.text)
        let delivered = texts.compactMap(SessionMessage.parse)
        if !texts.isEmpty, delivered.count == texts.count {
            opener = .sessionMessages(delivered)
        } else if !input.isEmpty || !turn.more.isEmpty {
            opener = .prompt
        } else {
            opener = .none
        }
    }

    /// Turn inputs the engine writes itself (`protocol.rs` CONTINUE_NOTE / SUSPENDED_NOTE,
    /// `background.rs` dropped pieces after a restart).
    static func isEngineNote(_ input: String) -> Bool {
        if input.hasPrefix("<resumed after the app ") { return input.hasSuffix("; continue>") }
        // Only the opening can match: a long brief must not cost a regex over all of it.
        guard input.first?.isNumber == true else { return false }
        return input.prefix(120).firstMatch(of: #/^\d+ background pieces? from before the engine restarted (was|were) dropped, not re-armed: /#) != nil
    }
}

/// A turn the engine started on background wakes alone: one compact line per wake (glyph,
/// id, what it was, how it ended, a link to the job's log), on the left like the session
/// message card, never as a user bubble. The model's answer follows as usual.
struct WakeEventRows: View {
    let events: [WakeEvent]
    let jobs: [String: BackgroundJob]
    /// Only the newest few until asked: a turn woken by a thousand jobs is one transcript row,
    /// and building every line of it at once beachballed opening the session.
    @State private var shown = Self.page
    static let page = 12

    var body: some View {
        let hidden = max(0, events.count - shown)
        VStack(alignment: .leading, spacing: 3) {
            if hidden > 0 {
                Button("Show \(min(hidden, Self.page * 4)) earlier of \(hidden)") { shown += Self.page * 4 }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            ForEach(hidden..<events.count, id: \.self) { i in
                WakeEventRow(event: events[i], job: jobs[events[i].id])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One collapsed system line, the row family for everything that isn't someone talking: a
/// background wake, a message from another session, a notice. Collapsed by default like a tool
/// row (glyph, source and type, the useful fields, one line); a click shows the full payload.
struct EventLine: Equatable {
    var glyph: String
    /// Source and type: "monitor mon-8", "okc manager · message".
    var title: String
    /// The useful fields after it: outcome, then a one-line detail.
    var fields: [String]
    /// Everything, behind the click. Empty when the line already says it all.
    var payload: String
    var warning = false
    /// A job's log file, linked from the line.
    var log: String?
    /// The session a message came from, linked from its title.
    var session: String?

    /// The collapsed line as text: "monitor mon-8 · timed out · no match after 2400s".
    var line: String { ([title] + fields.filter { !$0.isEmpty }).joined(separator: " · ") }

    init(glyph: String, title: String, fields: [String], payload: String, warning: Bool = false, log: String? = nil, session: String? = nil) {
        self.glyph = glyph
        self.title = title
        self.fields = fields
        self.payload = payload
        self.warning = warning
        self.log = log
        self.session = session
    }

    /// A wake: its type and id, its outcome, then what it was (the job's command, the timer's
    /// note) or the first line of what the agent was told.
    init(wake: WakeEvent, job: BackgroundJob?) {
        let firstLine = wake.body.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        var detail = job.map(\.label).flatMap { $0.isEmpty ? nil : $0 } ?? firstLine
        // The line says it once: when the detail is the payload's own first line, it doesn't
        // repeat it (a "Background command …" row that shows the command three times).
        if detail == firstLine { detail = "" }
        let (glyph, kind): (String, String) = switch wake.kind {
        case .job: ("terminal", "job")
        case .monitor: ("eye", "monitor")
        case .timer: ("alarm", "timer")
        case .task: ("person.crop.circle.badge.checkmark", "task")
        case .note: ("info.circle", "notice")
        }
        self.init(
            glyph: glyph,
            title: [kind, wake.id].filter { !$0.isEmpty }.joined(separator: " "),
            fields: wake.kind == .note ? [firstLine] : [wake.outcome, detail],
            payload: wake.body == firstLine ? "" : wake.body,
            warning: wake.failed,
            log: job?.log)
    }

    /// A message from another session (or the system): who, that it's a message, its first line.
    init(message: SessionMessage) {
        let who = message.isSystem ? "system" : (message.name.isEmpty ? message.from : message.name)
        let lines = message.body.split(whereSeparator: \.isNewline)
        let first = lines.first.map(String.init) ?? ""
        self.init(
            glyph: message.isSystem ? "bell" : "arrow.turn.down.right",
            title: "\(who) · \(message.isSystem ? "notice" : "message")",
            fields: [first],
            payload: lines.count > 1 || first.count > 140 ? message.body : "",
            session: message.isSystem ? nil : message.from)
    }

    /// An engine notice: one line; a longer one expands.
    init(notice text: String, warning: Bool) {
        let lines = text.split(whereSeparator: \.isNewline)
        let first = lines.first.map(String.init) ?? ""
        self.init(
            glyph: warning ? "exclamationmark.triangle" : "info.circle",
            title: first,
            fields: [],
            payload: lines.count > 1 ? text : "",
            warning: warning)
    }
}

struct EventLineView: View {
    let event: EventLine
    @State private var expanded = false
    @Environment(\.openSessionID) private var openSessionID

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The tool rows' icon column, so an event's title lines up with theirs.
            HStack(spacing: TurnSpace.Inset.row) {
                Image(systemName: event.glyph)
                    .frame(width: TurnSpace.Inset.icon)
                title
                ForEach(Array(event.fields.filter { !$0.isEmpty }.enumerated()), id: \.offset) { i, field in
                    Text("·").foregroundStyle(.tertiary)
                    Text(field)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(i == 0 && event.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                if let log = event.log {
                    Button("log") { Platform.open(URL(fileURLWithPath: log)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .help(log)
                }
                if !event.payload.isEmpty {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .contentShape(.rect)
            .onTapGesture {
                guard !event.payload.isEmpty else { return }
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            }
            if expanded {
                Text(event.payload)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, TurnSpace.Inset.iconColumn)
            }
        }
        .font(.caption)
        .foregroundStyle(event.warning && event.fields.isEmpty ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(expanded || event.payload.isEmpty ? "" : "Show all of it")
    }

    @ViewBuilder private var title: some View {
        if let id = event.session, let openSessionID {
            Button { openSessionID(id) } label: { Text(event.title).fontWeight(.medium) }
                .buttonStyle(.plain)
                .help("Open the session that sent this")
        } else {
            Text(event.title).fontWeight(.medium)
        }
    }
}

struct WakeEventRow: View {
    let event: WakeEvent
    let job: BackgroundJob?

    var line: EventLine { EventLine(wake: event, job: job) }
    /// What the piece was: the job's command, the monitor's check, the timer's note.
    var headline: String { line.fields.last ?? "" }

    var body: some View { EventLineView(event: line) }
}
