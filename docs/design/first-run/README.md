# First run vs the hype reel

Audit of 2026-11-17, at v0.6.3 (`68f669a7`). The hype reel (PR #399, `video/hype-reel/`) draws an
idealised product: a model menu with this Mac's models first, inline pairing, six sessions
working on named machines, a call that reruns elsewhere "with one line saying so", priced Frog
Cloud models, a found `CLAUDE.md`, and the install line. This doc walks what a new user actually
gets on each surface, compares it beat by beat, ranks the gaps, and lists what this PR already
fixed.

How it was walked, without touching anyone's machine:
- **CLI:** `cargo build -p frog`, run with a throwaway `HOME` and `XDG_*`, `FROG_KEYCHAIN=off`,
  no local servers, `open` stubbed. `frog login` was stopped at the browser step, and `frog setup`
  after about 4 s of the 2.2 GB download. `site/install.sh` was read (it matches frog.toys/install.sh
  byte for byte), not run.
- **Mac:** offscreen snapshot tests only (`BackgroundHost`: alpha 0, never key) and the parity
  stills. The pairing and permission stills come from a throwaway offscreen test, since deleted.
  `mac-new-chat.png` and `mac-model-menu.png` were rendered against a real `HOME`; for the menu
  that is the same state a fresh Mac is in, since no local engine is running.
- **Web:** vite dev against the vendored mock gateway, plus a stub for the routes the mock lacks
  (`/v1/me`, `/v1/models` with today's live list, `/v1/repos`, `/v1/machines`). The real signed-in
  path was driven in headless Chrome with a throwaway profile. (Avatars are blocked in the stills;
  the broken image comes from the harness, not the product.)

Not measured: time to a first answer. The weights download was stopped after about 4 s, and
nothing signed in to Frog Cloud. So the CLI's local path is "a 2.2 GB download, minutes on
typical broadband", and the Frog Cloud path was never timed end to end. The `before` stills on
every surface were taken before this PR's fixes. The `after-web-*` stills were re-shot on the
same harness once the fixes were in.

## Decide first

1. **Put this Mac's models back in the Mac's model menu?** The reel's opening beat is a menu
   with local models first at $0. The app left them out on purpose (`ModelList.swift:8-11`,
   2026-10-30). On a fresh Mac today, the chip says Apple Intelligence and the menu doesn't list
   it. Gap 2 below.
2. **Ship `frog-apple` with the CLI (or let the CLI find it inside Frog.app)?** Without it, a
   new CLI user's first `frog` is an error. With it, a Mac on macOS 26 answers at once, as
   `docs/onboarding.md` promises. It adds to the tarball and the release job. Gap 1.
3. **A place field per session in the gateway's listing (zest)?** Without it, no web row (and
   no unloaded Mac row) can say which machine or place a session runs on, the reel's "six working,
   each on its machine". It's a protocol change across two repos. Gap 4.

Smaller calls: the Mac picker's price unit ("$0.55/M out", output only) vs the web's new "$0.0396
in · $0.55 out /M"; whether `s.state === 'running'` on the gateway means a turn is running (then
the web list can say "Working…" today).

Sizes: **S** is copy, a label, an empty state or a number (an hour or so). **M** is a component
or a reducer case, a day or two. **L** needs a protocol field, a gateway change or a product
decision.

## The reel, beat by beat

| Beat | Does the product do it? | What a new user hits instead |
|---|---|---|
| Model menu: this Mac's models first (Qwen3 32B, Qwen3 Coder 30B), then Frog Cloud's three, one click, "$0 a token" | **No.** | **Mac:** "Your machines" reads "No models on your machines yet." (`ModelPicker.swift:172`). Apple Intelligence, which the chip starts on, isn't in its own menu, so nothing has a checkmark. There are no download rows and no "$0". Frog Cloud showed five models A→Z, two of them the 8B side-job helpers, at "$X/M out". Leaving local models out was a deliberate call (`ModelList.swift:8-11`, 2026-10-30). No Qwen3 Coder 30B anywhere in `SuggestedModel.all`. **Web:** "Run it on your Mac" points to the Mac app; Frog Cloud had the 8B helpers, the default last, and "from $0.17/M" (input only, rounded). **CLI:** no model at all; it exits 1. One click to switch does work on both apps. |
| "Pair a machine…" turns into six code boxes; the row joins as the code lands | **Partly.** | Pairing exists and the code really is typed on the Mac (`PairSheet.swift`). But it goes sheet → second sheet (titled "Use mew"; now "Pair mew"), and the row appears only once the sheet closes, 1.2 s after success (`PairSheet.swift:187`). One action has three names: "Pair a machine…", "Pair…", "Use mew". |
| Six sessions working, each "Working…" and its machine | **No.** | **Mac:** a breathing dot. A running session nobody has open fell back to "repo · N turns · model" (now "Working…"). No row names a machine, though `Status.ranOn` is on the wire. **Web:** only the open session streams, and `look()` ignores `s.state`, so background sessions never show work. Their titles stay the repo name. `SessionSummary` has no place or machine field at all (`protocol.ts:174-193`; the gateway list is id/title/repo/branch/state/updated). |
| A call on a machine that dropped out says so in one line, then where it reran | **Partly.** | The engine's line is **"mew stopped answering; finishing on this Mac"** (`crates/frog-engine/src/provider/node.rs:43`, a warn notice after `ItemsDiscarded`). If no node is left: "mew stopped answering and no other node has this model right now". **Mac:** draws it as a loose notice between rows, not on the rerun call. Info-level retries and Frog Cloud's stand-in ("… is answering for now") went only to the log (now shown). **Web:** no `items_discarded` case, so a retried call leaves the partial and the retry stacked (a duplicated reply). `ran_on` isn't parsed. The stand-in line was rewritten to "Frog Cloud is busy right now." (now kept). **CLI:** labels every retry "busy, retrying…". It doesn't handle `ItemsDiscarded`, so the dead node's half-reply stays above the rerun. |
| Frog Cloud's models with their prices | **Yes, roughly.** | Live prices reach both pickers. The static `site/pricing.html` had DeepSeek V4.1 Flash at $0.165 / $0.0033 / $0.66; live is $0.0396 / $0.011 / $0.55 (fixed; the $0.165 is the cap, which `data-max` already carries). The web rounded $0.165 to "$0.17" and showed input only (fixed). The Mac shows output only, "$0.55/M out" (left; see "Decide first"). |
| Finds `CLAUDE.md`, skills and MCP servers; nothing to set up twice | **Used, not said.** | The engine reads `AGENTS.md` / `FROG.md` / `CLAUDE.md` up the tree, `~/.claude/CLAUDE.md`, skills in `.claude/skills` (cwd only) and `~/.claude/skills`, and `.mcp.json`. `~/.claude.json` MCP only after an opt-in. Claude Desktop's config, `.claude/CLAUDE.md` and `CLAUDE.local.md` are not read. **Mac:** the setup line ("Using your Claude Code setup: CLAUDE.md, 14 skills. Found 2 MCP servers. Use them") shows only while MCP servers are left to add, and once closed it never returns. **CLI:** says nothing; `frog --setup` prints a Rust `Debug` dump. **Web:** nothing. |
| `curl -fsSL https://frog.toys/install.sh \| sh`, frog.toys | **Yes.** | 12.6 MB, a few seconds. It ended without a next step (fixed). Without minisign, which is most Macs, it prints a loud uppercase WARNING. The tarball has no `frog-apple`, so the CLI can't give the instant Apple Intelligence answer `docs/onboarding.md` promises. |

## CLI

| Step | What happens today | What the reel implies | Gap | Size |
|---|---|---|---|---|
| Install | `downloading…`, `signature verified` (or a 3-line WARNING), `installed frog v0.6.3 to ~/.local/bin/frog`, PATH hint | install, then talk | No next step (**fixed**: "next: run frog in a project. frog login signs in to Frog Cloud; frog setup puts a model on this Mac"). Loud minisign warning. | S |
| `frog`, nothing set up | exits 1 in 0.03 s: "frog didn't find a model to talk to", six options, Frog Cloud fourth as `export FROG_API_KEY=…` | a first answer | No answer. Frog Cloud was offered as an env var (**fixed**: `frog login` first, setup's size stated). No Apple model: `frog-apple` isn't shipped. | S done, M left |
| Which model, why | `-m` → config → last used → cloud key → `pick_default` (tang → Ollama → LM Studio → Apple → cloud → Anthropic) | the menu says where | `pick_default`'s reason is built and dropped (`main.rs:515`). Three "default cloud" names: deepseek (real), qwen3-coder-next (login hint, **fixed**), glm (help example). | S |
| Banner | `context window: … auto-compacting past …` and `compiled memory: on (<200-char path>)` before ` ✻ frog  model  cwd` | a clean card | Diagnostics above the brand line. Nothing about what it found. | S |
| `frog setup` | tang-llm 20 MB in about 3 s, then `model.safetensors: 16 / 2158 MB (0%)`, no rate or ETA, restarts from zero if interrupted; ended `ready. try: frog -p "reply with just: ok"` | ready in a moment | The size shows only when the big file starts. No resume. Odd closing line (**fixed**: "ready. run frog in a project to start."). `frog setup --help` looked up a model named `--help` (**fixed**). | S done, M left |
| `frog login` | `signing in to Frog Cloud with github in your browser…`, then silence for up to 180 s; success hint `frog -m cloud/qwen3-coder-next` | one click | Looked hung (**fixed**: a waiting line). The hint named the wrong model (**fixed**). No mention of the $1. | S |
| `frog account` | `model: local/qwen3-4b (on this machine, free)` on a machine with no model | truthful | Wrong: it uses `cfg.resolve`, not the chain `frog` uses. "frog cloud" lowercase (**fixed**). | S |
| `frog --help` | 73 flag lines, internal ones included; no login, setup or account | discoverable | **Fixed:** the commands are listed under the flags. Hiding internal flags is left. | S / M |
| `--providers` | Ollama and LM Studio "connected" with neither running | truthful | No probe (`providers.rs:365`). | S |
| `--skills`, `--mcp` | refuse without a model | read-only listings | They run after model resolution. | S |

## Mac

Stills: [new chat](mac-new-chat.png), [project](mac-new-project.png), [composer](mac-composer-new-chat.png),
[model menu](mac-model-menu.png), [Settings › Models](mac-settings-models.png),
[a machine](mac-settings-machine.png), [pair: none found](mac-pair-empty.png),
[found](mac-pair-found.png), [code](mac-pair-code.png), [wrong code](mac-pair-wrong.png),
[setup line](mac-setup-line.png), [first card](mac-permission-first.png),
[outside the sandbox](mac-permission-outside.png), [card in a Frog Cloud session](mac-permission-card-cloud.png),
[a session](mac-session.png). All taken before this PR's fixes. The parity stills some of these come from predate the composer rework, so their composer copy is old; `composer.sh` and `fuzz.sh` weren't re-run here.

| Step | What happens today | What the reel implies | Gap | Size |
|---|---|---|---|---|
| First launch | the frog on its pad, "What should we work on?" twice (heading and placeholder), up to three recent-project chips; footer "Sign in to Frog Cloud · $1 free to start" | where it will run, up front | Nothing on the page says where a session runs. The question is repeated. In a project the heading is just the folder name. | S |
| Model menu | "Your machines: No models on your machines yet.", then Frog Cloud A→Z at "$X/M out", "Manage…" | this Mac first, $0, Frog Cloud below | See the beat table. The 8B helpers are **fixed** (left out, as on the web). | L (decision) |
| Settings › Models | This Mac "not running" / "Engine not running"; Frog Cloud "Not signed in" with no button; "Pair a machine…" | a place to finish setup | It reads as broken on a fresh Mac. It's a dead end for the menu's "Manage…". | S |
| Pairing | sheet "Pair a machine" → sheet "Use mew" with 3+3 boxes → "mew joined your machines." → closes after 1.2 s, then the row appears | inline boxes, the row joins as the last digit lands | Sheet on sheet, delayed row. Three names (**fixed**: "Pair mew"). Error copy said "frog" and "a newer tang" (**fixed**). | M |
| Session rows | title and a breathing dot; line 2 is the live step only for loaded sessions, else "repo · N turns · model" | "Working…" and the machine | **Fixed:** "Working…" on running rows with no step (two-line rows only; rows inside a project group stay one line). No machine (needs `ranOn` in the listing). | S done, M left |
| First permission card | "Allow this command?", the command, "Runs on this Mac · sandboxed", Deny, Allow | says where | The footer was hard-coded: wrong in a Frog Cloud session and under "outside the sandbox" (**fixed**; it now matches the web card's "Runs in your Frog Cloud sandbox"). Still wrong when Settings › Permissions turns the shell sandbox off. Title-case buttons "Allow Once", "Deny with a Note…" (**fixed**, with three in the cloud-consent sheet and "Use them"). | S |
| Tool rows | "Read …", "Ran …", "Edited …"; no machine | each call tagged | Tools run where the session runs; only model calls go to nodes. No turn footer says where the model ran. | M |
| Found setup | the setup line, only while MCP servers are left to add | always named | Users with CLAUDE.md and skills but no MCP servers to add are told nothing. | S |

## Web

Stills: [signed out](web-signed-out.png), [new session](web-new-session.png), [repo menu](web-repo-menu.png),
[model menu](web-model-menu.png), [first turn](web-first-turn.png),
[out of credit, today](web-out-of-credit-today.png), [the card it should show](web-out-of-credit-legacy.png),
[session list](web-session-list.png). Taken before this PR's fixes. After:
[model menu](after-web-model-menu.png), [empty repo menu](after-web-repo-menu-empty.png),
[out of credit on today's engine](after-web-out-of-credit-today.png).

| Step | What happens today | What the reel implies | Gap | Size |
|---|---|---|---|---|
| Signed out | "What should we work on?", "Frog is a coding agent for your repos…", "$1 free to start.", three pitch cards, chips, composer with "No repo · Auto · DeepSeek V4.1 Flash · Sign in" | clean | "$1 free" didn't say it needs GitHub (**fixed**, matching pricing.html). | S |
| New session, $1 account | "No sessions yet…", the same hero; chips assume a repo while the chip says "No repo" | a welcome | No line saying "$1.00 of Frog Cloud credit". | S |
| Repo menu, App not installed | "No repo ✓", "+ Give Frog access to more repos" | — | No why; "more" when there are none (**fixed**: "Frog sees only the repos you give it access to." and "Pick repos on GitHub"). Install link shown before GitHub was connected (**fixed**). | S |
| Model menu | "Run it on your Mac", then Frog Cloud in gateway order incl. Qwen3 8B and VL 8B, "from $0.04/M" | priced, default first | **Fixed:** helpers out, default first, "$0.0396 in · $0.55 out /M" to three significant figures. No speed shown. | S done, M left |
| First turn | composer reads "Default model" and "Ask" until the engine's first `status` | shows what you picked | Should fall back to the spec and mode you started with. | S |
| Out of credit | the engine ends with `billing_limit` (since 2026-11-01); the web showed "The turn stopped (billing limit)." and a Continue that is refused again; no card, no Paused row | the "add credit" card | **Broken, fixed:** `outOfCredits` matched only the old 402 error. Card copy now says "Frog Cloud credit" and weekly plans. | M (done) |
| Session list | only the open session streams; background rows show no work, titles stuck on the repo | six working, with machines | `look()` could use `s.state`, but check with zest that `running` means a turn and not just a sandbox up. No place field. | S / L |
| Call rows | no machine; no `items_discarded` (duplicated reply after a retry) | rerun line | See the beat table. | M |
| Mock gateway | no `/v1/me`, `/v1/models`, `/v1/repos`, `/v1/machines`, no out-of-credit switch, no `status` | — | That's why the out-of-credit break went unseen. | M (zest) |

## The ten gaps that most hurt the first five minutes

1. **The CLI's first run ends in an error.** Bare `frog` exits 1 with a menu of commands, and a
   Mac with Apple Intelligence can't answer because `frog-apple` isn't in the tarball. *Fix:* ship
   `frog-apple` in the darwin tarball (`release.yml` copies only `frog` + README), or let
   `sidecar::binary` find it in `/Applications/Frog.app/Contents/MacOS/`. When nothing is found on
   a TTY, ask once: "Frog Cloud (sign in) / This Mac (2.2 GB) / I have a key", then run
   `login` or `setup` inline and start. **M.**
2. **The Mac's model menu on a fresh Mac has nothing local and no checkmark.** The reel's
   opening beat is the menu. *Fix:* list This Mac's models first: Apple Intelligence (ready), the
   RAM-suited Qwen3 as a "Get · 18 GB" row, and Qwen3 Coder 30B if it's meant to be the coding
   pick. Each gets "$0" where a price would be and tok/s once measured; Frog Cloud below. The
   rows exist in the unmounted `ModelSettings`. **L, and it reverses the 2026-10-30 call, so it's
   Cam's.**
3. **Out of credit on the web showed a dead end** (fixed here). The card never appeared on
   today's engine, and Continue spent another refused call. *Left:* the mock should end turns
   with `billing_limit` so this can't regress unseen. **M (zest).**
4. **Nothing says where work runs.** No session row or turn names a machine on any surface. The
   web has no field for it. *Fix:* (a) a turn-footer and row suffix "on mew" from `Status.ranOn`,
   already on the wire to the Mac; (b) `ran_on` in the session listing (Mac `SessionInfo`, zest's
   `SessionSummary`) so unloaded rows can say "Working… · mew"; (c) web: show "Working…" from
   `s.state` once zest confirms its meaning. **M (Mac), L (web, crosses zest).**
5. **A dropped machine looks like a glitch, not a feature.** The engine's line exists, but the
   web duplicates the reply and the CLI leaves the dead node's half-reply on screen. *Fix:* handle
   `items_discarded` in the web reducer and the CLI renderer (FrogKit already does), and draw the
   rerun as a badge on the rerun step: "reran on this Mac · mew dropped out". Record failovers in
   `usage` (e.g. `failovers: [{from, to}]`) so the receipt can say "ran on mew, finished on this
   Mac". **M.**
6. **What Frog found isn't said.** It uses CLAUDE.md, skills and `.mcp.json`, but only the Mac
   says so, and only when there are MCP servers to add. *Fix:* one line on every surface, from
   `imports::report`: "Using CLAUDE.md · 4 skills · 1 MCP server" (CLI banner, Mac empty page per
   folder, web under the Starting steps via an engine event). Replace `frog --setup`'s Debug dump
   with the same sentence. Read `.claude/CLAUDE.md` and `CLAUDE.local.md` too. **S (CLI, Mac), L (web).**
7. **Pairing is a sheet on a sheet, and the row arrives late.** *Fix:* expand inline in
   Settings › Models: "Pair a machine…" becomes the found node and six boxes in place; on success
   insert the row with a short animation and collapse the boxes. Reuse `PairSheet`'s digit binding
   and `Devices.pair`. **M.**
8. **Settings › Models is a dead end for a new user.** "Not signed in" with no button; "Engine not
   running" reads as a fault. *Fix:* a "Sign in…" menu beside it (as `UserFooter` has); "Starts
   when you pick a model on this Mac" until a local model has ever run, keeping "Engine not
   running" for a crash. **S.**
9. **The local model is a 2.2 GB wait with no ETA and no resume.** *Fix:* say the size before
   downloading, show rate and ETA, range-resume the `.part`, and let the user start on Frog Cloud or
   Apple's model while it downloads. **M.**
10. **Prices don't read the same twice.** Web now shows in and out per million tokens to three
    significant figures. The Mac shows "$0.55/M out". The CLI's `--models` shows none (it has
    `cost_in`/`cost_out`). pricing.html's static table can drift again. *Fix:* one format everywhere,
    `$0.0396 in · $0.55 out /M` (Mac `ModelPrice`, CLI `--models`). Have `site/build.sh` or the worker
    fill the table from `/v1/models` so it can't go stale. **S (format), M (build-time table).**

Also small and worth doing next, but not done here: the banner's diagnostics (CLI), `frog account`
claiming a model that isn't there, `--providers` saying "connected" with nothing running,
`--skills` / `--mcp` needing a model, the web composer reading "Default model" before the first
`status`, the doubled "What should we work on?" on the Mac, and trimming internal flags out of `frog --help`.

## Fixed in this PR

- **Web:** out-of-credit card and Paused row on `billing_limit`; no Continue banner for it. The
  picker leaves out the 8B helpers, puts the default first, and shows in and out prices to three
  significant figures; the Settings price table uses the same format. The repo menu's empty state;
  no install link before GitHub is connected. Today's engine notices kept as words. Copy: "Frog
  Cloud credit", weekly plans, "$1 … when you connect GitHub". Tests in `model-names`, `turn-end`,
  `thread`, `composer-view`.
- **Site:** DeepSeek V4.1 Flash's static row (`pricing.html:103`) now has live numbers. The installer ends
  with the next step.
- **CLI:** the no-model message leads with `frog login`; login waits out loud and points at
  `frog`; `frog setup` ends usefully and has `--help`; `frog --help` lists the commands; "Frog Cloud"
  capitalised in `--providers`, `frog account` and its errors.
- **Mac:** the permission card says where the step runs (this Mac, outside the sandbox, or
  your Frog Cloud sandbox). Running rows say "Working…". Retry and Frog Cloud stand-in notices
  show. The 8B helpers are out of the picker. "Pair mew", and error copy that says "Frog" and "tang-llm". The
  pair hint names the toggle. Sentence-case buttons. "18 GB", not "18.0 GB". Tests in `OneLookTests`.
