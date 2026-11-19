import Foundation
import Observation

/// A new Frog Cloud session from Send to its first turn (the web's `ui/Opening.tsx`, #447): one
/// conversation, its sent message drawn once as the first turn, and the live row under it saying
/// how far the start has got, then carrying on as the turn's own row.
///
/// Every stage is something the Mac really knows: the `POST /v1/sessions` in flight (reserving),
/// the gateway's session state `starting` (booting, or cloning with a repo: the gateway doesn't
/// say which), `running` (the engine is up; the turn starts next), or `error` with its reason,
/// or the POST's own failure. The socket's welcome (and `CloudLink`'s idle after it) comes before
/// the boot is done, so it is not a sign of progress.
@MainActor
@Observable
final class CloudStart {
    enum Stage: Equatable { case reserving, booting, engine }

    /// What was sent and where.
    let text: String
    let repo: String?
    /// When Send was pressed.
    let since: Date
    /// The words the row has been given, oldest first, each from when it was true. The row
    /// shows them through `StartWords.steady` (no more than one change per 1.2 s).
    private(set) var said: [StartWords.Said] = []
    private(set) var stage: Stage = .reserving
    /// It couldn't start: why, in words.
    private(set) var error: String?
    /// When the gateway first said the sandbox is up: no turn 30 s after, the engine didn't
    /// pick the message up.
    private(set) var upSince: Date?
    /// The first turn started (the engine numbered it): the row hands over to the turn's own.
    private(set) var handedAt: Date?
    /// The session, once the POST answers.
    var session: String?
    /// The person typed the message in the composer (`Op.submit`'s `typed`); a Try again that
    /// sends it again as it was is the app's, so its fresh start is untyped.
    let typed: Bool
    /// Try again (the workspace's: a fresh start, or the message again when it's stuck).
    @ObservationIgnored var onRetry: (() -> Void)?

    init(text: String, repo: String?, since: Date = .now, typed: Bool = false) {
        self.text = text
        self.repo = repo
        self.since = since
        self.typed = typed
        said = [StartWords.Said(at: since, words: words)]
    }

    /// The row's words now, from what's known (the stuck reason is time's, see `StartWords.at`).
    var words: StartWords { StartWords.of(stage: stage, repo: repo, error: error) }

    var failed: Bool { error != nil }

    /// Stuck: up for `StartWords.stuckAfter` with no turn.
    func stuck(at now: Date) -> Bool { error == nil && handedAt == nil && upSince.map { now.timeIntervalSince($0) >= StartWords.stuckAfter } == true }

    func reached(_ stage: Stage, at now: Date = .now) {
        guard error == nil, handedAt == nil, stage != self.stage else { return }
        self.stage = stage
        if stage == .engine, upSince == nil { upSince = now }
        record(at: now)
    }

    func fail(_ why: String, at now: Date = .now) {
        guard handedAt == nil, error != why else { return }
        error = why
        record(at: now)
    }

    /// The sandbox is up but no turn came: the message goes again, and the 30 s start over.
    func resent(at now: Date = .now) {
        upSince = now
        record(at: now)
    }

    /// The engine started the first turn: its row takes over, showing `first` ("Thinking").
    func handOver(to first: String, at now: Date = .now) {
        guard handedAt == nil else { return }
        handedAt = now
        said.append(StartWords.Said(at: now, words: StartWords(verb: first, object: "", failed: false)))
    }

    /// Seconds from `now` until the hand-over has shown for `StartWords.settle` (it waits its
    /// turn behind the dwell like any change), when the turn's own row takes over.
    func settleDelay(after now: Date) -> TimeInterval {
        let last = StartWords.steady(said, now: .distantFuture)
        return max(0, last.since.addingTimeInterval(StartWords.settle).timeIntervalSince(now))
    }

    private func record(at now: Date) {
        let w = words
        if said.last?.words != w { said.append(StartWords.Said(at: now, words: w)) }
    }
}

/// What the start's row says, and when (pure, so it's tested). The words are verbs.json's `start`.
struct StartWords: Equatable {
    var verb: String
    /// The failure's reason, in muted; "" otherwise.
    var object: String
    /// "Failed": the verb in `warn`, the dot grey, and Try again.
    var failed: Bool

    struct Said: Equatable {
        var at: Date
        var words: StartWords
    }

    /// Nothing for this long: a quick start never shows the row (its height is kept).
    static let quiet: TimeInterval = 0.6
    /// At most one change this often.
    static let dwell: TimeInterval = 1.2
    /// Up for this long with no turn: the engine didn't pick the first message up.
    static let stuckAfter: TimeInterval = 30
    /// The hand-over shows for this long before the turn's own row takes over.
    static let settle: TimeInterval = 0.3

    static func of(stage: CloudStart.Stage, repo: String?, error: String?) -> StartWords {
        if let error { return StartWords(verb: Verbs.Start.failed, object: error, failed: true) }
        let verb = switch stage {
        case .reserving: Verbs.Start.reserving
        case .booting: repo.map(Verbs.Start.cloning) ?? Verbs.Start.booting
        case .engine: Verbs.Start.engine
        }
        return StartWords(verb: verb, object: "", failed: false)
    }

    /// What's been said with the stuck failure added, at the moment it became true.
    static func at(_ said: [Said], upSince: Date?, handed: Bool, now: Date) -> [Said] {
        guard !handed, let up = upSince, now.timeIntervalSince(up) >= stuckAfter, said.last?.words.failed != true else { return said }
        return said + [Said(at: up.addingTimeInterval(stuckAfter), words: StartWords(verb: Verbs.Start.failed, object: Verbs.Start.stuck, failed: true))]
    }

    /// What the row shows at `now`, and what it showed before (cross-fading out), with `n`
    /// counting the changes so each gets its own identity. Each value is held at least `dwell`;
    /// then the newest one known by then shows. With reduced motion (`steady: false`) it is the
    /// newest, at once.
    struct Shown: Equatable {
        var now: StartWords
        var was: StartWords?
        var n: Int
        /// When `now` started showing.
        var since: Date
    }

    static func steady(_ said: [Said], now: Date, steady: Bool = true) -> Shown {
        guard let first = said.first else { return Shown(now: StartWords(verb: "", object: "", failed: false), was: nil, n: 0, since: now) }
        guard steady else {
            let last = said.last { $0.at <= now } ?? first
            return Shown(now: last.words, was: nil, n: 0, since: last.at)
        }
        var shown = Shown(now: first.words, was: nil, n: 0, since: first.at)
        var i = 1
        while i < said.count {
            let at = max(shown.since.addingTimeInterval(dwell), said[i].at)
            guard at <= now else { break }
            var j = i
            while j + 1 < said.count, said[j + 1].at <= at { j += 1 }
            if said[j].words != shown.now {
                shown = Shown(now: said[j].words, was: shown.now, n: shown.n + 1, since: at)
            }
            i = j + 1
        }
        return shown
    }
}

/// A cloud conversation's link before its session exists (the POST is out): ops wait here and go
/// to the session's `CloudLink` once it's attached, so the conversation on screen from Send is
/// the one that carries on.
@MainActor
final class PendingCloudLink: ConversationLink {
    var onEvent: (Envelope?) -> Void = { _ in }
    private(set) var inner: ConversationLink?
    private var waiting: [Op] = []
    private var stopped = false

    init() {}

    var endDescription: String { inner?.endDescription ?? "" }
    var isAlive: Bool { !stopped && (inner?.isAlive ?? true) }

    /// The session's link: everything sent so far goes to it, in order.
    func attach(_ link: ConversationLink) {
        guard !stopped else { return link.stop(reason: "stopped before it opened") }
        if let old = inner {
            old.onEvent = { _ in }
            old.stop(reason: "replaced")
        }
        inner = link
        link.onEvent = { [weak self] env in self?.onEvent(env) }
        let ops = waiting
        waiting = []
        ops.forEach(link.send)
    }

    /// Back to before the POST (a fresh start after a failed one): nothing waits, and the
    /// failed session's link goes.
    func reset() {
        waiting = []
        if let old = inner {
            old.onEvent = { _ in }
            old.stop(reason: "start again")
        }
        inner = nil
    }

    func send(_ op: Op) {
        if let inner { inner.send(op) } else { waiting.append(op) }
    }

    func stop() { stop(reason: "stopped") }

    func stop(reason: String) {
        guard !stopped else { return }
        stopped = true
        waiting = []
        if let inner { inner.stop(reason: reason) } else { onEvent(nil) }
    }
}
