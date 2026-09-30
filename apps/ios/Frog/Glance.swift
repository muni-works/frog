import Foundation
import WidgetKit

/// Keeps widgets and the Control Center control current: a snapshot into the shared group, and a
/// reload only when what they'd show has changed.
@MainActor
enum Glance {
    static func share(_ sessions: [RemoteSession], host: String?) {
        let rows = sessions.filter { $0.live == .waiting || $0.live == .running || $0.open }.prefix(20).map { s in
            Snapshot.Row(id: s.id, title: s.title, live: s.live?.rawValue ?? "", activity: s.activity,
                         question: s.question?.text, permission: s.question?.id, local: s.isLocal, open: s.open)
        }
        let old = Snapshot.load()
        guard old?.rows != Array(rows) else { return }
        Snapshot(rows: Array(rows), host: host, at: .now).save()
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}
