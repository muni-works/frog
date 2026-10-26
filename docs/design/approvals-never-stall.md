# Approvals never stall (2026-10-24)

Evidence: ~15 wasted 10-minute approval windows in one day, all on safe calls — MCP reads
(`planetscale_list_databases`, `planetscale_list_organizations`), `git fetch` + `git show`, and
identical retries of a call already denied. Managers run in default mode, so auto-only
allowances didn't reach them. Goal: an agent never sits on a card for a call that's plainly
safe or already refused; Cam is interrupted only for finished work, a real issue, or a
conversation.

All four mechanisms are in `crates/frog-engine/src/engine.rs` (`permit`, `run_tools`) with the
predicates in `auto.rs`.

## 1. Read-only MCP tools never card, in every mode

`auto::mcp_read`: the tool's own name (after the server's name when it repeats it,
`mcp__planetscale__planetscale_list_databases` → `list_databases`) opens with `list`, `get`,
`read`, `search`, `describe` or `stream` (`_` or `-`), or, on the vcad server only, with `see`,
`inspect`, `measure`, `describe` or `render`. Any word that writes, runs, starts/stops or hands
out a secret (`create`, `execute`, `run`, `password`, `token`, `key`, …) disqualifies it. Checked
before the mode, so default mode gets it too. Auto mode keeps its older, slightly wider
`read_tool` list on top. `planetscale_execute_read_query` is deliberately NOT covered (not named
for a read); grant or answer it.

## 2. Write-tier trust grant: `[mcp_trust]`

```toml
[mcp_trust]
planetscale = "write"
```

`Config::mcp_trust: BTreeMap<String, McpTrust>` (`read` | `write`), empty by default. With a
write grant, `auto::mcp_write` decides which of that server's calls skip the card: planetscale
`execute_write_query` and tools named with write/create/delete/drop/alter/apply/insert/update;
runpod `create-pod`, `delete-pod`, `pod-action` only (not secrets or clusters); other servers,
the same write words. Every granted call emits a notice (`mcp_trust: ran {server} › {tool} …;
args: …`), a `permission_decision` with layer `trust`, and an engine-log line under `--serve`.
Without the grant writes card exactly as before.

## 3. Never burn a window twice in a turn

Each card's deny (the user's, or the timeout's) is recorded per call: hash of tool name + exact
arguments → the denial text. An identical call later in the same turn doesn't ask: it's denied,
the batch's remaining calls are skipped, and the turn ends with the new
`EndReason::BlockedOnApproval { denial }` (serde `{"type":"blocked_on_approval","denial":…}`),
plus a `Blocked on approval: …` notice. Cleared at each turn start.

The brief assumed no Swift change was needed. Not quite: `EndReason`'s Swift decoder sent
unknown types to `.error(…)`, which throws without an `error` key, so the whole `turn_ended`
would have been dropped and the turn never seen to end. Added `.blockedOnApproval(String)` to
`apps/FrogKit/Core/Protocol.swift` and its two exhaustive switches (Activity, TranscriptView)
plus `Conversation.summary`. The broker's idle report (`SessionBroker.lastReport`) already
appends `(turn ended: …)`, which now carries the denial text to the parent session.

## 4. Session circuit breaker

The same call denied on a card `DENIED_LIMIT` (2) times in one session never asks again: it's
denied at once with the notice "this call was denied twice and won't ask again this session"
and the denial goes back to the agent as a note, so it carries on. Counts live on the engine's
`Agent` (`session_denied`), across turns.

## Also fixed: auto mode carded its own temp scratch

In auto mode a `Write` to a fresh `/private/tmp/…` file carded "writes outside the project":
`ctx.outside()` treats temp dirs as scratch (so the provenance branch never ran), while the edit
rule's `hard_rule` only knows the project root. Auto mode now allows Write/Edit when
`approval::path_in_own_scope` holds (fresh under the temp dir, or created this session);
another session's existing temp file still asks.

## Manager briefs

Managers' ssh carded because sandboxed ssh can't read `~/.ssh/known_hosts`. The default manager
brief should include `[sandbox] allow_read = ["~/.ssh/known_hosts"]` (docs/reference.md, "ssh
to user hosts").

## Tests

`engine.rs`: `read_verb_mcp_tools_never_card_in_default_mode`,
`non_read_mcp_tools_still_card_without_a_grant`,
`a_write_grant_runs_writes_cardless_and_logged_and_cards_without_it`,
`a_denied_call_retried_in_the_same_turn_ends_it_blocked`,
`a_call_denied_twice_in_a_session_is_auto_denied_after`,
`auto_mode_writes_its_own_fresh_temp_scratch_without_a_card`. `auto.rs`:
`mcp_reads_in_every_mode_are_read_verbs_only`, `mcp_write_patterns_are_scoped_by_server`.
`config.rs`: `mcp_trust_is_empty_by_default_and_grants_only_what_it_names`.
