# Models: local and cloud

Spec, written 2026-09-28. Status: built, except three things that wait on the engine: Auto (step 3), the Unreachable state, and starting on Apple Intelligence while the first download runs. See "Not built yet" at the end.

frog runs models on your Mac and in the cloud. This spec makes that difference visible and deliberate everywhere a model appears, and makes every appearance of a model look, read and behave the same.

## Why

Today one model shows up at least nine different ways:

| Where | What it shows |
|---|---|
| Settings default picker, Model menu, Race sheet | the raw spec: `tang/mlx-community/Qwen3-4B-4bit` |
| Command palette | "Model: ollama/qwen3:4b", subtitled "native tools · medium tier" |
| Empty conversation | "ollama/qwen3:4b · native tools · medium tier" |
| Activity capsule | a short name, with "-4bit" patched to " 4-bit" by hand |
| Hover tips | "… · native tool calls · medium tier" |
| Settings model row | a shortened spec and "Medium" |

That's three names for one model, internal words ("tier", "tool mode", "tang", "ollama") that mean nothing to the person reading them, and no answer anywhere to the question people actually have: **where does my code go, and what does it cost?**

## Principles

1. **Where your code goes is always visible.** Every model, everywhere, carries the same mark for "on this Mac" or "cloud". Nothing leaves the Mac without the person having chosen a cloud model or allowed one for the project.
2. **One model, one look.** A model's name, icon, abilities and state come from one place and are drawn by one view. No view formats a model on its own.
3. **Plain words.** People see names, places, abilities, speed and cost. Plumbing (engines, specs, tiers, tool modes) lives in Settings > Advanced and ⌥-hover.
4. **Works first, asks later.** A new install can chat immediately, upgrades itself when a better model is ready, and asks a question only when the answer changes where code goes or what it costs.
5. **Native.** System controls, SF Symbols, VoiceOver labels and menu-bar commands, so frog reads as a Mac app, not a web view.

## Vocabulary

Use these words, and only these, in every string about models.

| Concept | Say | Don't say |
|---|---|---|
| Runs locally | **On this Mac** | local, tang, ollama, MLX, sidecar |
| Runs on your own server | **On mew** (the server's name) | server, remote, LAN, custom provider |
| This Mac and your servers together | **Your devices** ("Keep It on Your Devices") | local, self-hosted, on-prem |
| Runs remotely | **Cloud · Anthropic** (the provider's name) | API, remote, hosted, provider id |
| Apple's on-device model | **Apple Intelligence** | apple, foundation model |
| Can call tools | **Uses tools** | native tools, text tools, tool mode |
| Accepts images | **Sees images** | vision, multimodal |
| Thinks before answering | **Reasons** | reasoning tokens, thinking budget |
| How capable it is for agent work | (not shown; frog adapts on its own) | tier, small/medium/large |
| Speed | **38 words/s** (measured on this Mac) | tok/s, estimated speeds |
| Price | **Free**, **~4¢ a turn**, **$1.84 this week** | per-M-token prices (hover only) |
| Doesn't fit | **Needs 32 GB** | OOM, too large |
| The automatic choice | **Auto** | router, handoff, cascade |

Model names are the catalog's display names ("Qwen3 8B", "Claude Sonnet 5"). Quantization is shown only when two variants of one model are both installed ("Qwen3 8B · 4-bit").

## The model, described once: `ModelIdentity`

A value type built in one place (`ModelIdentity(entry:catalog:machine:usage:)`) from what frog already knows: `ModelEntry` (spec, source, caps), `CatalogModel` (name, inputs, reasoning, tools, costs), `SuggestedModel` (download size), `ProviderStore` (keys), and measured usage.

| Field | From | Notes |
|---|---|---|
| `name` | catalog `name`, else a cleaned-up model id | never the spec |
| `maker` | catalog provider, or the model family for local models | "Qwen", "Anthropic" |
| `place` | `ModelEntry.source` and the provider | `.mac` (tang, ollama), `.apple`, `.server(name)` (your own servers), `.cloud(provider)`; a config.toml profile follows its provider's local flag, and anything unknown counts as cloud |
| `abilities` | caps and catalog | `usesTools`, `seesImages`, `reasons` |
| `fit` | parameter count, quantization, this Mac's memory | `.fits`, `.tight`, `.wontFit(needs: GB)`; local only |
| `speed` | measured words/s on this Mac, per model | nil until the first turn |
| `cost` | catalog prices × this person's recent average turn size | nil for local |
| `state` | downloads, keys, reachability, project policy | see States |
| `spec` | `ModelEntry.spec` | for ⌥-hover, Settings > Advanced and the engine only |

Fit uses the weights' size plus room for context: `weights × 1.2 + 2 GB` against physical memory. Over 90% is `.tight` ("May be slow on this Mac"); over 100% is `.wontFit`.

## The model, drawn once: `ModelLabel`

One view, `ModelLabel(identity, size:)`, in four sizes. Every surface picks a size; none builds its own.

| Size | Shows | Used by |
|---|---|---|
| `.pill` | place icon, name, state badge | composer picker, activity capsule readout |
| `.row` | place icon, name, ability icons, one line of detail (fit and speed, or cost), state action | model picker, Settings > Models, first run |
| `.menu` | name, place as a subtitle, checkmark | Model menu, Settings default picker, Race sheet, command palette |
| `.caption` | place icon and name in secondary text | empty conversation, turn footer, session hover |

The place icon is `laptopcomputer` for On this Mac, `apple.intelligence` for Apple Intelligence, `server.rack` for your own servers, `cloud` for Cloud. Cloud names carry a faint tint of the cloud color, while On this Mac stays neutral. Like Safari's lock, the signal is small, always in the same spot, and never loud.

VoiceOver reads every size as one element: "Qwen3 8B, on this Mac, free" or "Claude Sonnet 5, cloud, Anthropic, about 4 cents a turn".

## States

A model is in exactly one state. Each state has one badge, one line, one action, and they're the same on every surface.

| State | Badge | Line | Action |
|---|---|---|---|
| Ready | none | detail as usual | Use |
| Downloading | progress ring | "2.1 of 4.6 GB" | Pause / Resume |
| Not downloaded | `arrow.down.circle` | "4.6 GB download" | Get |
| Needs a key | `key` | "Add an Anthropic key or use Frog Pro" | Add key… |
| Won't fit | dimmed row | "Needs 32 GB, this Mac has 24" | none |
| Unreachable | `cloud.slash` / `bolt.horizontal.circle` | "Anthropic isn't responding" / "Ollama isn't running" | Use a model on this Mac |
| Not allowed here | `lock` | "kiln keeps code on this Mac" | Allow for this project… |

Actions happen in place: Get downloads right there in the row, and Add key opens a sheet over the picker, not Settings. One control, `ModelStateAction`, does them wherever a row appears (the picker, Settings, first run).

Built so far: Ready, Not downloaded, Downloading, Download failed (Retry), Needs a key, Won't fit. **Unreachable** waits on the engine: `frog --models` leaves out models it can't reach, so the app can't tell "not running" from "not there". It needs the engine to list them with a reachability flag. **Not allowed here** comes with project permission (step 4). `SnapshotTests.testRenderModelLabels` renders every size × state × place to `$TMPDIR/frog-snapshots/model-labels.png` for review.

## One list

The picker and Settings > Models show the same list, built by `ModelSections` and drawn by `ModelListRow` (`ModelList.swift`):

- **Sections say where models run,** in one order everywhere: On this Mac, then each of your servers ("On mew (RTX 3090)"), then each cloud provider ("Cloud · Anthropic"), then **Get more** (recommended downloads). Within a section: ready, then ones that need something, then ones that can't be used.
- **One row:** the name and ability icons over one line of detail (measured speed, estimated cost per turn, size, or the state line), then a checkmark for the current model, then the list's accessory. The section names the place, so the row doesn't. Hovering shows the details (abilities, context, price, spec).
- **The current model is always listed,** even when frog didn't report it (an Ollama model with Ollama not running).

## The picker

A menu over that list, 340pt wide: no lane switch and no side card. The search field appears once you type (or when there are more than ten models). Ready models are picked; the rest do what makes them ready (Get, Add Key…, Allow…). With no cloud model set up, a single Cloud row offers Add Key…. Auto will sit on top once the engine can switch models (see "Not built yet"). Manage Models… opens Settings.

## Settings > Models

The same list, with managing instead of choosing: models downloaded to this Mac have Show in Finder and Remove from This Mac; cloud models have Hide. Below it: Providers (keys, Add Server…, and Choose Cloud Models…, a sheet over the catalog), Spending once a cloud provider is connected, and Advanced.

## Where code goes

- **The mark.** Every `ModelLabel` shows its place icon, including the turn footer, so any past turn shows where it ran.
- **Per-project permission.** The first time a project's code would go to a cloud model, frog asks once, in a sheet over the composer:
  > **Use cloud models in kiln?** Files you mention and tool output are sent to the provider.
  > [Keep it on this Mac] [Just this conversation] [Always allow]
- **Keep it on this Mac** puts the Cloud lane in the Not allowed here state and makes Auto local-only. The choice is shown in the lane caption and can be changed in the project's title menu. Plain chats (no folder) ask the same question once, for all chats.
- **Where it lives.** frog keeps the answer in `~/.config/frog/projects.json` (the nearest folder with an answer decides) and enforces it at session start, on model switches, and for the auto-mode classifier, which falls back to the session's model. `frog --cloud-policy [allow|deny|ask]` reads or sets it. "Cloud" means the endpoint leaves your devices: hosted APIs, or any server that isn't localhost, a bare or `.local` name, a private or Tailscale address.
- **Just this conversation** allows cloud until the conversation changes. In a folder that said no, it first resets the answer to Ask, since frog enforces a no.
- **Built:** the sheet, the Not allowed here state with Allow…, the lane caption ("kiln allows cloud models", "You'll be asked before kiln's code goes to the cloud"), and a Cloud Models picker in the title menu (Ask First / Allow / Keep Code on Your Devices).
- **Switching lanes mid-conversation** says so once, in the transcript: "From here on, turns go to Claude Sonnet 5 (cloud)." No alert.

## Cost and speed

- **Turn footer** (next to the existing token count): the model caption, then "3¢" for cloud or "41 words/s" for local. Tokens stay on hover.
- **Activity capsule hover:** the conversation's total cost, or average speed.
- **Measured speed:** words/s per model on this Mac, from finished turns, a rolling median of the last 20. The picker shows it once there is one.
- **Estimated cost:** the catalog price times this person's median turn size, rounded to a friendly number ("~4¢ a turn"). Before any history, a default turn of 8k in and 1k out.
- **Built:** `ModelStats` keeps per-model speeds (words/s, the median of the last 20 turns), turn sizes, learned prices and weekly spend. The engine now names the model in each turn's usage (`TurnUsage.model`), so a turn is priced by the model that ran it even after a switch. The turn footer shows the model caption, then cost or speed; tokens are on hover. The picker shows measured speed for your devices and "~4¢ a turn" for cloud. The capsule's hover adds the conversation's cost. "tok/s" joined the banned words.
- **Spending cap** (Settings > Models > Cloud, with step 6): optional, per month. At 80% frog says so once. At 100%, Auto goes local-only and cloud models go to a Paused state with "Raise cap…".

## First run

The empty conversation's "Run a model on this Mac" card becomes a choice, and chatting works before anything is chosen.

- **Immediately:** Apple Intelligence where it's available, labeled as such in the pill. Otherwise the composer says "Choose a model to start".
- **Two cards, side by side:**
  - **On this Mac:** the recommended model for this Mac's memory (Qwen3 8B at 16 GB and up, Qwen3 4B below). "Private and free. 4.6 GB, once." [Get]
  - **Cloud:** "The strongest models, from about 4¢ a turn." [Sign in to Frog Pro] [Add a key…]
- **When the download finishes:** the conversation switches to it if it's still empty, and the transcript says once: "Qwen3 8B is ready and now your default."
- **Afterwards:** the card shrinks to a single line in the empty state, "Qwen3 8B on this Mac · Change", then goes away once there are two ready models.

## Motion and feel

- **Switching models:** the pill's icon and name change in place with `contentTransition(.symbolEffect)` and `.numericText()`-style text, never a pop.
- **Downloads:** the row's ring fills, then collapses into the checkmark when it's done, and the row moves into the Ready group with a matched-geometry move.
- **Warnings:** only when something changes where code goes or what it costs. They're written as one sentence in the transcript, never modal, except for the one-time project permission.
- **Reduce Motion** swaps all of the above for crossfades.

## Guardrails

Consistency has to be enforced, or it erodes one feature at a time.

- **Snapshot tests** (`FrogTests/SnapshotTests.swift`) render `ModelLabel` in every size × state × place, light and dark. A visual change shows up as a diff in review.
- **No raw specs in views** (`ModelIdentityTests.testViewsNameModelsOneWay`). The test scans `Frog/Views` for `.spec` on lines that show text (`Text(`, `.help(`, `title:`, `subtitle:`, `Label(`, `Section(`, `Button(`), ignoring ids and tags, and fails with a pointer to this doc.
- **Vocabulary check.** The same test fails on string literals on those lines that contain "tier", "tool calls", "tool mode", "tang" or "ollama". "tok/s" joins the list when speed moves to words/s (build step 5).
- **The exception is marked.** A line that is meant to show engine details (Settings' engine hover, the detail card's spec, server setup naming its software) ends with `// advanced`, so every exception is visible in review.
- **This doc** is the reference: a new model surface picks a `ModelLabel` size, and a new state is added to the table here first.

## Build order

1. **`ModelIdentity` and `ModelLabel`, swapped into all nine surfaces.** No redesign: same places, one look, plain words. Add the guardrail tests. This removes most of the inconsistency on its own.
2. **States.** Wire downloads, keys, fit and reachability into `ModelIdentity.state`, with actions working in place in the current picker.
3. **The two-lane picker and Auto.** Lanes are built. Auto needs the engine first: it has no model routing today, so a turn can't switch models mid-way. The engine needs a hard-step signal and a way to continue a turn on another model, which is the local↔cloud handoff in bet 5.
4. **Per-project cloud permission** and the lane caption.
5. **Cost and speed:** measured speed, cost estimates, turn footer, spend and cap.
6. **First run and Settings > Models.**

Steps 1 and 2 are app-only. Steps 3–5 need small engine additions: an escalation signal for Auto, per-turn cost in `turnEnded` usage, and a project policy the engine enforces as well as the UI, so the terminal app keeps the same promise.

## Not built yet

- **Auto.** The engine can't switch models mid-turn. It needs a hard-step signal and a way to continue a turn on another model (bet 5's local↔cloud handoff).
- **Unreachable.** `frog --models` leaves out models it can't reach. It needs to list them with a reachability flag.
- **Starting on Apple Intelligence.** The first run shows the choice cards, and the conversation switches to the downloaded model when it's ready. Starting on Apple's model meanwhile needs the engine's default-model choice to prefer it when nothing else is installed.
- **Frog Pro sign-in** on the Cloud card, once Pro exists. Until then the card offers Add a Key….

## Open questions

1. **Is Auto the default once cloud is set up?** Proposed: yes, for new projects that allow cloud; existing conversations keep their model.
2. **Frog Pro or bring-your-own-key first?** Proposed: Frog Pro is the first-run path (one sign-in, no keys), and keys are the advanced path in Settings. That depends on Pro shipping; until then, keys are the only path and the cloud card says "Add a key…".
3. **Is cloud permission per project or global?** Proposed: per project, with plain chats sharing one answer.
4. **Words/s or tokens/s?** Proposed: words/s in the UI (people read words), tokens/s in Advanced and in `frog bench`.
