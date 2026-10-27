# Elegant and legendary

Plan, 2026-10-27. It comes from the codebase audit (Oct 26–27) and four research passes:
- engine refactor
- model insides
- app tools and thin client
- bench and CI

Mockup: [design/insides/mockup.html](../design/insides/mockup.html).

**Thesis.** Shrink the core, and be the thing nobody else can be.
- The audit's engine bugs clustered in two places: one 85-field `Agent` struct, and the model-compensation layer.
- frog's unfair advantages are that it owns its inference, it has a native app, and it's local and private.

---

## Phase 0: discipline (this week)

These are small, independent changes, and each ships alone.

**Relay and site**
1. **Relay auth.** Have `apps/macos/Frog/Model/RemotePush.swift` send `Authorization: Bearer <secret>`, with the secret kept in Keychain. Pushes from real phones currently 401 silently. Log non-2xx responses as well, not just 410.
2. **Kill the Vercel relay.** Delete `site/api/` and `site/vercel.json`, or put the same auth on them. Right now they have no auth.
3. **Gate the site deploy.** Add a `node --test site/test` job, and make `site.yml` `needs:` it.
4. **Test the Workers relay itself.** Point `site/test/push.test.js` at `functions/api/_apns.js` instead of the Vercel copy.
5. **Stop publishing source.** Give the Pages build its own public dir (`site/public`), so `site/api` and `site/test` aren't served.
6. Add `site/.wrangler/` to `.gitignore`.

**Engine bugs that don't need the refactor**
- Use `checked_add` for Instant in `background.rs`. Done: `761aff6`.
- Bash timeout test pgrep collision. Done: `c09b13d`.
- De-flake `a_replys_read_only_calls_run_concurrently` by counting how many calls are in flight at once instead of timing them.
- Feed wake notices into the turn as prefix text, not as user input. That way they skip `@mentions`, `/skills` and image attachments, and aren't pinned by compaction.

**Privacy receipt**
- Nothing phones home by default. The only outbound host is `api.frog.toys`, and only when the user chooses frog cloud.
- Say so in the README, and add a test that the default config makes no requests to anything but localhost.

**Lint**
- Turn on `clippy -D warnings` once the 20 style warnings are fixed. Never `cargo fmt` the engine crate; run rustfmt on the files you touch only.

## Phase 1: elegance, the engine refactor

The goal is that `/clear`, a folder change, a model switch and a resume each become one call that can't forget a field. Each step compiles and passes `cargo test -p frog-engine` on its own.

**The state split**

`engine.rs` is 14.2k lines: about 6k of code and 8.2k of tests. `Agent` has about 85 fields. Group them by how long they live:

| Lifetime | Type | Reset by |
|---|---|---|
| process | `Agent` (cfg, store, shared, meter, chapter_titles…) | never |
| folder | `Project` (root, rules, skills, memory, repo_map, mcp*, worktree_lock, classifiers, allows) | `Project::open(root)` |
| model | `Harness` (caps, tier, mode, failures, fallback, reprobed) | `Harness::for_profile` |
| conversation | `Conversation` (messages, inputs, session_id, pending, chapters, notes, wake_hold…) | `reset_conversation(Clear \| Resume \| Folder)` |
| turn | turn locals (active_turn, timing, turn_denied…) | turn start |

Making these types fixes several audit bugs by construction:
- `/clear` keeps `pending` and `wake_hold`.
- The folder change ignores `worktree_lock` and keeps `mcp_ready_queue`.
- `text_fallback` survives SetModel.

**Migration order**

Do one commit per step. Land steps 1–2 fast, because they conflict with everything.

1. Move the file only: `git mv engine.rs engine/mod.rs`.
2. Split the test block into `engine/tests/*.rs`. Check that `cargo test -- --list | wc -l` gives the same count before and after.
3. Extract `Harness` with no behaviour change. Then a separate commit makes `set_model` use `for_profile`, with a new test: SetModel after a fallback returns to native.
4. Extract `Conversation` and route `Op::Clear` through `reset_conversation`. New tests: Clear drops `pending`; Clear resets `wake_hold`.
5. Extract `Project` and route `use_folder` through `Project::open`. New tests: the lock follows the folder; the ready queue is emptied.
6. Move the router into `router.rs`, then `call.rs`, `dispatch.rs`, `permit.rs`, `turn.rs`. These are plain `impl Agent` blocks.

**Risks**
- Borrow splits at emit sites. Handle them mechanically, without redesigning while moving code.
- Check the `ClearInbox` semantics before dropping `pending`, because the user may have just queued it.
- `mode` and `intended_model` are restored from the log, so they stay in `reset(Resume)`.
- Keep `apply_harness` running after reset. Rename it `rebuild_system`.

## Phase 2: the agent touches the app

Extend the existing engine link, not an app-hosted MCP server.
- `SetClientCaps` already gates `sessions` and `panes`, and `SessionRequest`/`SessionReply` is the template to copy.
- Identity, lifecycle and approvals come for free.
- An MCP shim for outside agents can come later.

**Protocol**
- Add `caps.app` and one generic pair: `Event::AppRequest { id, tool, args }` / `Op::AppReply { id, result, error }`.

**v1 tools**
- `OpenPane`, `ShowDiff`, `PinGitCard`, `Notify` (rate-limited by the app), `RevealInFinder`, `OpenInEditor`.
- Extend `StartSession` to take `worktree`/`branch`.

**Permissions**
- UI-only tools are read-only class: no prompt, but they still show as items in the transcript.
- `StartSession` follows the mode rules.

**Files**
- `protocol.rs`
- new `tools/app.rs`
- `FrogKit/Core/Protocol.swift`
- `Conversation.swift`
- new `AppBroker.swift`, calling Panes, GitIndex, Notifier and Workspace

**Thin client**

| Swift | Verdict |
|---|---|
| Titler | engine is the source of truth; Swift is the on-device fallback and sends back `SetTitle` |
| Chapters | engine emits `ChapterStarted` boundaries; Swift only draws them |
| RemotePush | engine emits `Event::Attention`; Notifier and RemotePush stop parsing raw JSON |
| Race | scoring/apply/discard become `frog race` CLI ops; the UI stays |
| GitIndex | the UI cache stays; landed/merge detection becomes `frog git status --json`, so the agent knows too |
| MorningNotice, UpdateDrain | keep, they're already thin |

Fix the GitIndex audit bugs while in there:
- The `pr` result is lost to the refresh race.
- git calls block the cooperative pool.
- Main-thread I/O in `compose`.
- A folder with no repo is cached permanently.

## Phase 3: show the model's insides

See the [mockup](../design/insides/mockup.html).

**What it shows**
- Inline shading where the model hesitated.
- A fork note when the runner-up was close.
- Gutter dots on unsure diff lines.
- A live pane with tok/s, draft acceptance, an entropy sparkline, an expert heatmap and layer-state bars.

**The honesty rules**
- Low probability ≠ wrong. Flag *forks* only: the top-2 gap is under 25 points, on a token that changes meaning.
- Group by identifier or argument. At most ~3 marks per turn.
- Expert ids get no human labels. Show fingerprints and differences only.
- Calibrate against frog-outcome probes before claiming anything.

**Wire format**
- OpenAI-compatible `logprobs`, plus an opt-in `tang` extension per chunk:
  - `t: [[lp, H, margin]…]`: about 6 B per token
  - `draft: [1,1,0]`
  - `route`: sampled layers only
- A `tang.summary` on the usage chunk.
- The UI keys off which fields are present, never off the provider name:
  - OpenAI, llama.cpp, vLLM and ollama get shading.
  - llama.cpp also gets draft stats.
  - Routing and state are tang only.
  - Anthropic shows nothing.

**Ship order**
1. **Draft speedometer.** Frog only. Read `timings.draft_n*` into `TurnUsage` and show "58% predicted ahead". About a day.
2. **Standard logprobs.** Parse `choices.logprobs` in `provider/openai.rs` into `Delta::Signals`, which is live-only. Turn-level "uncertain spans" readout.
3. **tang compact `t`/`draft` arrays.** Sampler and head changes in tang. Inline marks, then `arg_conf` on tool arguments.
4. **Per-turn routing histogram.** The "brain fingerprint" glyph.
5. **Sampled per-token routing and state norms.** Behind a debug toggle.

**Blocker for GLM internals**
- The suspected tang DSA bug: every layer uses layer 3's K/V (`docs/interp/architecture.md` §1.3).
- Confirm it with the tang owner first.

## Phase 4: local-first excellence and a public bench

**Bench v2.** Today `frog-bench` has 9 easy tasks and a hand-published `site/data/bench-v1.json`. v2 needs:
- 40–60 tasks across tiers (multi-file, ask, do-nothing, idle-turn cost), with a held-out slice.
- A roster of ~6 local models pinned by digest and quant, plus 2–3 cloud references.
- Every result stamped with the frog sha, model digest, server version, sampler and seed.
- repeat ≥ 3, pass@1 with a confidence interval, and pass^k.
- $ per solved task, tok/s, TTFT p50/p95 and energy.

**Harness levers.** Each one must show a bench delta in its PR.
1. Contract-error repair:
   - nearest span on an `old_string` miss
   - auto-read before edit
   - early stop on repeat loops
   - count text-mode parse failures
2. A stable prefix:
   - don't rebuild the repo map on resume
   - fit the Weak and Medium map budgets on the bench
3. Measured per-model presets (mode, thinking, map budget, guidance) shipped in the bundled caps, with overrides in Settings.

**Weekly and public**
- A self-hosted M4 Max runner and a cron `bench.yml`.
- It opens a PR adding `site/data/bench-YYYY-WW.json`.
- A scoreboard page with history and methodology.
- Preview deploys for site PRs; prod deploys on merge.

## Phase 5: cut

After phases 1–2, list every feature shipped in October, along with:
- its usage, from local logs only
- the lines it owns

Delete the bottom third.

## Order and parallelism

```
P0 ──┬─ P1 steps 1-2 (fast, solo) ─ P1 3-6 ─┬─ P2 (needs Conversation/Project)
     │                                       └─ P3.3+ (engine side)
     ├─ P3.1-2 (provider + app, independent of the refactor)
     └─ P4 bench v2 (independent)
```

These run independently, so each can be its own session: P0, P3.1–2, P4 bench v2, and the tang DSA confirmation. P1 is serial and goes first on `engine.rs`.
