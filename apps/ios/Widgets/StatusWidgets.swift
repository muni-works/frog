import AppIntents
import SwiftUI
import WidgetKit

/// frog at a glance: who needs you (answerable right there), what's running, or all quiet.
struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, snapshot: Snapshot(rows: [
            .init(id: "a", title: "Fix the flaky test", live: "waiting", question: "Run cargo test?", permission: "p", local: true),
            .init(id: "b", title: "Add dark mode", live: "running", activity: "Editing theme.swift", local: false),
        ], host: "Mac", at: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : StatusEntry(date: .now, snapshot: Snapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // The app reloads this whenever something changes; the hourly refresh only ages it.
        completion(Timeline(entries: [StatusEntry(date: .now, snapshot: Snapshot.load())], policy: .after(.now + 3600)))
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "frog.status", provider: StatusProvider()) { entry in
            StatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("frog")
        .description("What needs you, and what's running on your Mac.")
        #if os(watchOS)
        // A complication on the watch face.
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
        #endif
    }
}

struct StatusView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    private var waiting: [Snapshot.Row] { entry.snapshot?.waiting ?? [] }
    private var running: [Snapshot.Row] { entry.snapshot?.running ?? [] }
    private var mood: FrogMood { !waiting.isEmpty ? .waiting : !running.isEmpty ? .working : .idle }
    private var headline: String {
        if let q = waiting.first { return q.question ?? "frog needs you" }
        if let r = running.first { return r.activity ?? "Working" }
        return "All quiet"
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                FrogFace(mood: mood, size: 30)
            }
            .widgetURL(url(waiting.first ?? running.first))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label { Text(waiting.isEmpty ? (running.isEmpty ? "frog" : "frog is working") : "frog needs you") } icon: {
                    FrogFace(mood: mood, size: 14)
                }
                .font(.caption.weight(.semibold))
                Text(headline).font(.caption).lineLimit(2)
            }
            .widgetURL(url(waiting.first ?? running.first))
        case .accessoryInline:
            Text(waiting.isEmpty ? (running.isEmpty ? "frog: all quiet" : "frog: \(headline)") : "frog: \(headline)")
        #if os(watchOS)
        case .accessoryCorner:
            FrogFace(mood: mood, size: 22)
                .widgetLabel { Text(waiting.isEmpty ? (running.isEmpty ? "All quiet" : "Working") : "Needs you") }
                .widgetURL(url(waiting.first ?? running.first))
        default:
            EmptyView()
        #else
        case .systemMedium:
            medium
        default:
            small
        #endif
        }
    }

    #if os(iOS)
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                FrogFace(mood: mood, size: 34).tint(.frog)
                Spacer()
                if waiting.count + running.count > 1 {
                    Text("\(waiting.count + running.count)").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let top = waiting.first ?? running.first {
                Text(top.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(headline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(waiting.isEmpty ? Color.primary : Color.orange)
                .lineLimit(3)
            if let q = waiting.first, let p = q.permission {
                AnswerButtons(session: q.id, permission: p).controlSize(.mini)
            }
        }
        .widgetURL(url(waiting.first ?? running.first))
    }

    private var medium: some View {
        let rows = Array((waiting + running).prefix(3))
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                FrogFace(mood: mood, size: 40).tint(.frog)
                Spacer(minLength: 0)
                if let at = entry.snapshot?.at {
                    Text(at, style: .time).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                if rows.isEmpty {
                    Spacer(minLength: 0)
                    Text("All quiet").font(.headline)
                    Text("frog will let you know when it needs you.").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                ForEach(rows) { r in
                    HStack(alignment: .center, spacing: 8) {
                        Link(destination: url(r)!) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.title).font(.caption.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                Text(r.question ?? r.activity ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(r.live == "waiting" ? Color.orange : Color.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if r.live == "waiting", let p = r.permission {
                            Group {
                                Button(intent: DenyIntent(session: r.id, permission: p)) { Image(systemName: "xmark") }
                                    .tint(.gray)
                                Button(intent: AllowIntent(session: r.id, permission: p)) { Image(systemName: "checkmark") }
                                    .tint(Color(red: 0.18, green: 0.62, blue: 0.31))
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.circle)
                            .controlSize(.small)
                        }
                    }
                }
                if !rows.isEmpty { Spacer(minLength: 0) }
            }
        }
    }

    #endif

    private func url(_ r: Snapshot.Row?) -> URL? {
        URL(string: r.map { "frog://session/\($0.id)" } ?? "frog://")
    }
}

#if os(iOS)
/// Control Center (and the Action button): how many conversations need you, one tap to them.
struct NeedsYouControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "frog.needs-you", provider: NeedsYouValue()) { count in
            ControlWidgetButton(action: OpenFrogIntent()) {
                Label(count == 0 ? "All quiet" : "\(count) need\(count == 1 ? "s" : "") you", systemImage: count == 0 ? "checkmark.circle" : "hand.raised.fill")
            }
        }
        .displayName("frog")
        .description("Open what needs you.")
    }
}

struct NeedsYouValue: ControlValueProvider {
    var previewValue: Int { 1 }
    func currentValue() async throws -> Int { Snapshot.load()?.waiting.count ?? 0 }
}

/// Opens frog on the conversation that needs you most.
struct OpenFrogIntent: AppIntent {
    static let title: LocalizedStringResource = "Open frog"
    static let description = IntentDescription("Opens what needs you, or your conversations.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        let row = Snapshot.load()?.waiting.first ?? Snapshot.load()?.running.first
        let url = URL(string: row.map { "frog://session/\($0.id)" } ?? "frog://")!
        return .result(opensIntent: OpenURLIntent(url))
    }
}
#endif
