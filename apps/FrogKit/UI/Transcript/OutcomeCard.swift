import SwiftUI

/// What a finished worker leaves in the transcript (review-ux, step 2 — read-only): the claims
/// it made in its final message, each with the command that checks it, parsed from the turn's
/// last message on render. Every row is pending — the worker's say-so; frog runs the checks
/// itself in step 4. Replaces the changes strip for delegated work: diffs stay one click away
/// in the existing Changes tab (this card names the way), so nothing here opens a diff.
struct OutcomeCard: View, Equatable {
    let claims: [Claim]

    nonisolated static func == (a: Self, b: Self) -> Bool { a.claims == b.claims }

    var body: some View {
        VStack(alignment: .leading, spacing: TurnSpace.Inset.tight) {
            ForEach(claims) { claim in
                row(claim)
            }
            footer
        }
        .padding(TurnSpace.Card.padding)
        .background(Tokens.raised.opacity(0.6), in: .rect(cornerRadius: TurnSpace.Card.radius))
        .overlay(
            RoundedRectangle(cornerRadius: TurnSpace.Card.radius)
                .strokeBorder(Tokens.hairlineStrong, lineWidth: 1)
        )
    }

    /// One status row: the state glyph, the claim as the row's words, the check in quiet mono.
    private func row(_ claim: Claim) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TurnSpace.Inset.snug) {
            Image(systemName: Self.glyph(claim.state))
                .font(.system(size: 10, weight: claim.state == .pending ? .regular : .bold))
                .foregroundStyle(Self.color(claim.state))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: TurnSpace.Inset.hair) {
                Text(claim.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
                if let check = claim.check {
                    Text(check)
                        .font(.system(size: Tokens.Size.meta, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let evidence = claim.evidence {
                    Text(evidence)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .font(.frog(size: Tokens.Size.status))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// State color lives on the glyph only (Tokens' rule), never on fills or words.
    static func glyph(_ state: Claim.State) -> String {
        switch state {
        case .pending: "circle.dotted"
        case .passed: "checkmark"
        case .failed: "xmark"
        }
    }

    /// The glyph's color, from the tokens: pending is signal, pass is the accent, fail is fail.
    static func color(_ state: Claim.State) -> Color {
        switch state {
        case .pending: Tokens.signal
        case .passed: Tokens.accent
        case .failed: Tokens.fail
        }
    }

    /// The footer's copy: the one way out to the diffs, which the card never shows itself.
    static func footer(_ count: Int) -> String {
        count == 1 ? "1 claim · diffs in the Changes tab" : "\(count) claims · diffs in the Changes tab"
    }

    private var footer: some View {
        HStack(spacing: TurnSpace.Inset.snug) {
            Spacer(minLength: 0)
            Text(Self.footer(claims.count))
                .font(.frog(size: Tokens.Size.meta))
                .monospacedDigit()
                .foregroundStyle(.quaternary)
        }
    }
}

extension TurnState {
    /// This turn's outcome card, when its final message ends with a claims block and the flag
    /// is on (read-only, step 2). Nil otherwise: the changes strip renders as it always did.
    var claims: [Claim]? {
        guard FeatureFlags.outcomeCard, finished else { return nil }
        return Claims.fromTurn(self)
    }
}

extension SubagentRun {
    /// A delegated worker's claims, parsed from its final message on render (the report is the
    /// worker's final answer). Nil when the flag is off or the message makes no claims.
    var claims: [Claim]? {
        guard FeatureFlags.outcomeCard else { return nil }
        for item in items.reversed() {
            guard item.kind == .message, item.done else { continue }
            if let claims = Claims.parse(item.text) { return claims }
        }
        return nil
    }
}
