# iOS parity

How the iOS/watchOS surfaces stay in step with the Mac and the engine. Part of the
[ios analysis](inventory.md) workstream.

## The protocol

The engine's wire protocol ([`crates/frog-engine/src/protocol.rs`]) is the source of truth.
Everything on it is serde-serialized Rust; clients speak the same shapes:

- **Mac app / TUI** — the Rust types directly (in-process or over JSONL).
- **Swift** (`apps/FrogKit/Core/Protocol.swift`) — a hand-written `Codable` twin. It has
  already drifted once (`Op.permission` gained a `note` field; the iOS copy missed it), which
  is exactly the failure mode this section exists to end.
- **The schema artifact** — `crates/frog-engine/schema/frog-engine-1.json`, generated from
  the Rust types by `frog-engine::schema` (schemars 1.2, already in the lockfile via rmcp;
  no new dependency graph). One JSON Schema draft 2020-12 document: `$defs` for every type
  reachable from `Op` (client → engine) and `Envelope` (engine → client), and a top-level
  `anyOf` pointing at those two roots.

The artifact is versioned by filename (`-1`), not by content hash: it changes only when the
protocol changes, and the golden-file test `frog-engine::schema::tests::artifact_matches_types`
regenerates it on every `cargo test -p frog-engine` run and fails on drift. A deliberate
protocol change means committing the file the test just wrote — the diff is then the review
unit for "what changed on the wire", in one place, from one source.

Notes on the generation, for whoever touches it next:

- `Envelope` flattens an internally tagged enum (`Event`), which schemars cannot lower: a
  plain derive drops `seq`/`session`/`created` from every variant. `schema.rs` splices the
  envelope fields back into all 49 event variants by hand; the result is pinned by the
  `envelope_fields_are_spliced_into_every_variant` and `samples_validate` tests, which check
  real wire samples (including protocol.rs's own round-trip JSON) against the document.
- `Op::Wake` is `#[serde(skip)]`, so it is absent from the schema by construction — it is
  internal to the engine and never crosses the wire.

## Codegen pipeline (planned)

The next step is generating the Swift twin from the artifact instead of editing it by hand.
Status and the honest gaps:

- **Generated (this step):** the schema artifact + golden test. Rust derive, no hand-written
  schema.
- **Not yet generated: `Protocol.swift`.** Hand-editing it is out of scope for the schema
  step; the plan is quicktype-style generation from `frog-engine-1.json` into Swift
  `Codable` types, replacing the hand-written twin file-by-file (it compiles into every iOS
  target with no module, so the switch must keep the same internal names).
- **quicktype is not available offline here** (needs npm at generation time). Until a
  generator is vendored or a pinned version is added to dev tooling, the schema serves as
  the review contract: when `Protocol.swift` is edited, the reviewer diffs it against
  `frog-engine-1.json` rather than against memory.
- **Rust-typed only.** The Mac ⇄ phone bridge layer (`RemoteBridge.swift`: `hello`, `list`,
  `sessions`, `event`, …) lives in Swift with no Rust twin, so the schema cannot cover it.
  That is a separate protocol with its own drift risk; giving it a Rust-side definition
  would be the natural follow-up.
- **The session-list row** is Swift-typed only (`RemoteBridge.sessionList()` builds it from
  Mac-side `Library` state), same gap: no Rust type, no schema entry. Note that the bridge
  also never sends the parent link the Mac's `Library.parents` holds, so the phone's session
  list is flat — see [inventory.md](inventory.md).
- **serde details the schema preserves but codegen must respect:** `skip_serializing_if`
  fields are absent (not null) on the wire; `#[serde(flatten)]` on `Op::Answer` puts
  `choices`/`other` beside `id`; `u64` fields are `integer` with `format: uint64` (Swift
  `UInt64`, not `Int`).

[`crates/frog-engine/src/protocol.rs`]: ../../crates/frog-engine/src/protocol.rs
