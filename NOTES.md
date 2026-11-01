# billing-events — notes

Branch frog/billing-events, base c374000c (main, carries #235 model-policy). Engine half of the
two-repo billing fix (the edge half is with the frog cloud manager). Cam: "we shouldn't throw this
error, we should just transition to credits, but make it obvious." One commit per piece
(`git commit -s`), never push to main; push the branch and open a PR. Edit tool only for
Rust/Swift. Target dir /private/tmp/be-target (delete when the suite passes, ~11G).

## Pieces
0. This checkpoint.
1. protocol.rs — `Event::BillingLimit { window, reason, balance_micro }` (durable, serde-tagged,
   serde-default) + `EndReason::BillingLimit { window, reason, balance_micro }` (the typed
   out-of-credit end, never a provider error). Swift mirror in Protocol.swift.
2. provider/mod.rs — `HttpError { status, body, billing }` gains `billing: BillingHeader`
   (serde'd `x-frog-billing` header from the edge: `credit: <micros>`), `Billing::parse(body)`
   (insufficient_quota 402 body → window "5h"|"weekly"|"credit"), and
   `is_billing(status, body)` for sse::check. The edge's header is the source of truth when
   present; the body is the fallback until the edge ships.
3. engine/call.rs — the 402 arm before `is_fail_fast`: credit-admitted (`x-frog-billing: credit`
   with a balance, or a body that reads "add credit to keep going") emits `Event::BillingLimit`
   (info line, one per turn) and retries ONCE past the fail-fast wall (only when admitted);
   a hard refusal (no balance) errors with the typed path.
4. engine/mod.rs — classify backstop: a billing HttpError → `EngineError::Billing { status,
   message }` (a clean line, never the raw dump). Session EndState gains the mapping.
5. Engine tests — admit (event + one retry), hard refusal (typed end, no event), 5h-window
   admit, the raw body never surfaces, EndState wiring.
6. FrogKit — Protocol.swift decode (billingLimit event + endReason case), Conversation row
   (billingNote state), TranscriptView end-of-turn row (neutral notice / red banner with an
   add-credit button → https://frog.toys/?settings=billing), Activity.done case, ProtocolTests +
   BillingTests.

## Result
(engine + app numbers land here)

## Strings
- informational (credit available): "5-hour allowance used · billing credit at usage prices"
  (balance appended when the edge sent one: " · $1.23 left")
- hard out-of-credit: "out of credit · add credit" (banner, red accent, button → billing page)
