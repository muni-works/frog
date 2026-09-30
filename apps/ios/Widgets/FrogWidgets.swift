import ActivityKit
import SwiftUI
import WidgetKit

@main
struct FrogWidgets: WidgetBundle {
    var body: some Widget {
        TurnLiveActivity()
    }
}

extension FrogMood {
    init(name: String) {
        switch name {
        case "reading": self = .reading
        case "thinking": self = .thinking
        case "working": self = .working
        case "waiting": self = .waiting
        case "done": self = .done
        case "sad": self = .sad
        default: self = .idle
        }
    }
}

struct TurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TurnActivity.self) { context in
            LockScreenTurn(context: context)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(.frog)
        } dynamicIsland: { context in
            let state = context.state
            let waiting = state.waiting == true
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    FrogFace(mood: FrogMood(name: state.mood), size: 34).tint(.frog).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if state.mood != "done" {
                            Text(context.attributes.startedAt, style: .timer)
                                .monospacedDigit()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60)
                        }
                        Text("\(state.steps) step\(state.steps == 1 ? "" : "s")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.activity)
                            .font(.callout)
                            .foregroundStyle(waiting ? .orange : .secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if waiting, let p = state.permission {
                            AnswerButtons(session: context.attributes.session, permission: p)
                        }
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                FrogFace(mood: FrogMood(name: state.mood), size: 20).tint(.frog)
            } compactTrailing: {
                if waiting {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                } else if state.mood == "done" {
                    Image(systemName: "checkmark").foregroundStyle(Color.frog)
                } else {
                    Text("\(state.steps)").monospacedDigit().foregroundStyle(Color.frog)
                }
            } minimal: {
                FrogFace(mood: FrogMood(name: state.mood), size: 18).tint(waiting ? .orange : .frog)
            }
            .keylineTint(.frog)
            .widgetURL(URL(string: "frog://session/\(context.attributes.session)"))
        }
    }
}

/// Deny and Allow, right where the question is.
struct AnswerButtons: View {
    let session: String
    let permission: String

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: DenyIntent(session: session, permission: permission)) {
                Text("Deny").frame(maxWidth: .infinity)
            }
            .tint(.gray)
            Button(intent: AllowIntent(session: session, permission: permission)) {
                Text("Allow").fontWeight(.semibold).frame(maxWidth: .infinity)
            }
            .tint(Color(red: 0.18, green: 0.62, blue: 0.31))
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
    }
}

struct LockScreenTurn: View {
    let context: ActivityViewContext<TurnActivity>

    var body: some View {
        let state = context.state
        let waiting = state.waiting == true
        VStack(spacing: 12) {
        HStack(alignment: .center, spacing: 14) {
            FrogFace(mood: FrogMood(name: state.mood), size: 44).tint(.frog)
            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(state.activity)
                    .font(.headline)
                    .foregroundStyle(waiting ? .orange : .primary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if state.mood == "done" {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Color.frog)
                } else {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.headline.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64, alignment: .trailing)
                }
                Text("\(state.steps) step\(state.steps == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        if waiting, let p = state.permission {
            AnswerButtons(session: context.attributes.session, permission: p)
        }
        }
        .padding(16)
    }
}
