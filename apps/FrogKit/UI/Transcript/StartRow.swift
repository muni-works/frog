import SwiftUI

/// A new Frog Cloud session's start on the live row (the web's `LiveTail` given `start`, #447):
/// one stage at a time from what the gateway reports (`CloudStart`), each replacing the last with
/// the thought's cross-fade, nothing for the first 600 ms (its height is kept), at most one change
/// per 1.2 s, and at once with reduced motion. The dot holds still and is never amber here. A
/// failed start is "Failed" in `warn`, the reason in muted, and Try again. The clock under it runs
/// from Send.
struct StartRow: View {
    let start: CloudStart
    @Environment(\.turnSpace) private var space
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let now = ctx.date
            let said = StartWords.at(start.said, upSince: start.upSince, handed: start.handedAt != nil, now: now)
            let shown = StartWords.steady(said, now: now, steady: !reduceMotion)
            let visible = now.timeIntervalSince(start.since) >= StartWords.quiet
            VStack(alignment: .leading, spacing: space.gaps.stats) {
                row(shown)
                if !shown.now.failed {
                    StatsLine(stats: LiveStats(elapsed: now.timeIntervalSince(start.since), tokens: nil, soFar: false,
                                               perSecond: nil, slow: false))
                }
            }
            .opacity(visible ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: visible)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(shown.now.failed ? "\(shown.now.verb): \(shown.now.object)" : shown.now.verb)
        }
    }

    private func row(_ shown: StartWords.Shown) -> some View {
        LineFrame(hovered: false) {
            LiveDot(dot: shown.now.failed ? .stalled : .still)
        } content: {
            ZStack(alignment: .leading) {
                words(shown.now)
                    .id(shown.n)
                    .transition(reduceMotion ? .identity : .asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.24)),
                        removal: .opacity.animation(.easeIn(duration: 0.18))))
            }
            .animation(reduceMotion ? nil : .default, value: shown.n)
            if shown.now.failed, let retry = start.onRetry {
                Button(Verbs.Start.retry, action: retry)
                    .buttonStyle(.plain)
                    .font(.frog(size: Tokens.Transcript.status.size))
                    .foregroundStyle(Tokens.accent)
                    .fixedSize()
                    .padding(.leading, TurnSpace.Inset.tight)
            }
            Spacer(minLength: 0)
        }
    }

    private func words(_ w: StartWords) -> some View {
        HStack(spacing: TurnSpace.Inset.snug) {
            Text(w.verb)
                .font(.frog(size: Tokens.Transcript.status.size))
                .foregroundStyle(w.failed ? Tokens.warn : Tokens.text)
                .fixedSize()
            if !w.object.isEmpty {
                Text(w.object)
                    .font(.frog(size: Tokens.Transcript.status.size))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                    .help(w.object)
            }
        }
    }
}
