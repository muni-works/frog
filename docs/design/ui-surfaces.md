# ui surfaces: approvals, the inbox, the session header, the model picker

Status: design, proposed · 2026-10-25 · owner: frog manager.
Mockups: [ui-surfaces.html](ui-surfaces.html) (every state, light and dark; `t` flips the
theme, `?only=<id>` shows one state, `&t=light` deep-links light). Shots:
[ui-surfaces-shots/](ui-surfaces-shots/).

Builds on (all read for this pass):
- design system v0.1.0 (chief `design/system/`): tokens, components §3/§4/§7/§8/§11, voice.
  Every colour, size, radius and motion below is a token name from there.
- background work (chief `design/background/spec.md`): job states, waiting-on-you, the inbox,
  notification rules, grants (§8).
- delegated approvals (`docs/design/delegation.md`, frog/delegation-pipeline): the pipeline,
  hard vs soft classes, the second pass, the chief, the roll-up, the ≤5 cards/day target.
- onboarding v2 and accounts (`docs/design/accounts-ux.md`): sign-in adds, never unlocks;
  credits are tasks.
- today's code: `PermissionCard` + `ApprovalDetails` (FrogKit/UI/Transcript/ItemViews.swift:245),
  `QuestionBody` (Cards/QuestionBody.swift), `ActivityViewer` + `DegradedBadge`
  (macos/Frog/Views/ActivityViewer.swift), `ModelMenu` (macos/Frog/Views/ModelPicker.swift),
  `ModelSections` (Models/ModelList.swift), `Status.degraded` (Core/Protocol.swift:316, PR #96).

Not readable yet: the sidebar refactor (frog/sidebar-refactor-design has no doc committed, it's
still running). §2.4 states the seam this design needs from it, so the two can meet.

## 0. one grammar

The four surfaces are one system: they show the same objects with the same words, and they act
through the same four verbs.

**One object: the ask.** Everything that waits on a person is an *ask*: a permission card, an
`Ask` question, a dead manager, a cap about to act. Every ask has the same eight fields, and
every surface reads them from one record (the ledger's `approval / ask` job, background §1):

| field | what it says | today's source | new |
|---|---|---|---|
| who | session, then its chain: `okc bf16 proj · okc manager · chief` | `SessionNesting` | chain in the record |
| wants | verb + object, ≤6 words: "launch a pod", "delete a worktree" | `question` | — |
| why you | the rule that sent it *here*: a hard class, a grant that ran out, the chief falling back | `card.trigger`, `reason` | `class`, `trail` |
| the call | the exact command or diff | `arg`, `preview` | — |
| touches | the blast radius: paths (size, files, made-here), hosts, money (rate, cap, budget) | `card.touches` | `hosts`, `spend` |
| undo | `stoppable`, `reversible`, or `can't be undone` | — | `reversible` |
| frog's take | the recommendation, one line, medium weight | `card.recommendation` | — |
| age | how long it has waited: now, 4m, 2h | — | `asked_at` |

**One trail.** Every card that reaches a person shows how it got there, as one caption line of
steps: `auto flagged → context pass kept it → chief: over its cap → you`. It's the delegation
pipeline drawn as breadcrumbs. Steps are muted; the step that handed it to you is in `text`.
The trail is what makes a card feel *rare*: you can see three things already tried to decide it.

**Three weights.** A card's weight comes from its consequence, never from its tool:

| weight | when | border | lead glyph | allow is | shortcut |
|---|---|---|---|---|---|
| routine | soft class, chief didn't take it (timeout, busy, unreachable) | `warning` 45% | ✋ `warning` | primary, `Allow once` | ⌘↩ |
| spend | anything with a `spend` field (pods, paid APIs, cap raises) | `warning` 45% + budget meter | `$` in a ring, `warning` | primary when inside budget, else secondary | ⌘↩ inside budget only |
| irreversible | hard class: deletes outside scratch, force-push, prod deploy, posts, credentials | `danger` 60%, 1.5px | ⚠ `danger` | secondary, `danger` text, **hold 1.2s** | none |

Fills stay neutral glass on every weight (tokens: no state-tinted fills, orange over gray reads
brown). Weight is the border, the glyph, and how hard it is to say yes.

**Four verbs.** Every ask offers the same four outcomes, in the same slots, everywhere:

1. **Allow once** (⌘↩): the recommended choice is primary and first (components §4). When
   frog's take is deny, `Deny` takes the primary slot and Allow moves to secondary.
2. **Always…**: opens a scope picker, never a blank yes. Scopes, narrowest first: this command
   prefix in this session · this class for this session · this class for its manager and its
   workers (a grant, background §8, with a budget and a 4-week cap). Never offered on
   irreversible cards: hard classes can't be granted.
3. **Deny** (⌘.) and **Deny with note…** (quiet): the note goes back to the agent.
4. **Pass**: moves the card along the ladder. Below the top it says `Escalate` and hands the
   card up (worker → manager → chief → Cam). At the top (Cam) it says **Ask why…**: the card
   goes back to the agent for context, stays in the inbox as `asked agent · 2m`, and returns
   with the agent's answer appended. This follows the delegation rule that the fix for a
   missing-context flag is context, not a yes or a no.

**Shared marks.** Status glyphs are background §2's (spinner running, hollow ring idle, ✋ waiting,
red flatline dead, dashed red ring orphaned, red dot failed). Fact chips are components §3 (mono
11, `surface`, `line`, `radius.s`, a dot = verified by frog). Money is always monospaced digits,
with the cap beside it (`$31.70 of $42.32`). Ages are voice §8 (`now, 4m, 2h, 3d`).

## 1. approval card v2

### anatomy

```
┌───────────────────────────────────────────────────────────────────────────┐
│ ✋  okc serving patch wants to  ssh into its pod                     4m   │  title: glyph · who (medium) · wants (semibold) · age
│     auto flagged → context pass kept it → chief didn't answer in 5m → you │  trail (caption, muted)
│ ┌ ssh root@213.173.98.4 -p 22091 'cd /workspace && ./bench.sh' ────────┐ │  the call (code surface, mono 12)
│ └──────────────────────────────────────────────────────────────────────┘ │
│  why you   ssh-scratch: chief's class, chief busy with tang manager       │  rows: label (caption, faint, 64pt) · value
│  touches   [● pod wm3z… made by this session] [host 213.173.98.4]         │  chips
│  undo      stoppable: ending the ssh ends the bench                       │
│  frog's take  allow once: its own pod, read-mostly bench script           │  medium
│ [Allow once ⌘↩] [Always…]                    [Ask why…] [Deny with note…] [Deny ⌘.] │
└───────────────────────────────────────────────────────────────────────────┘
```

Padding 14, `radius.card`, glass. Width follows the transcript column (max 560). The agent's own
reason (`card.agentReason`) sits under the call in callout, muted, quoted, and clipped at 3 lines.
It's claimed, not verified, so it never gets a verified dot.

### variant A: routine class

The residue of the soft classes: the chief would normally take it, but it timed out, was busy,
or couldn't be resolved. The card says so in the trail, and its first line in the inbox reads
"chief didn't answer · 5m". It's the lightest of the three: warning border, Allow once primary.
Example: `okc serving patch` ssh into the pod it created.

### variant B: spend class

Adds a **budget row** above frog's take: a meter of this week's spend against the grant's budget
(`$48.10 of $60 · dg4 bench pods`), with this call's worst case drawn as a hatched segment on the
end (`+$42.32 at its 4h cap`). If the hatched segment crosses the budget, the meter's overflow is
`danger`, Allow drops to secondary, and the primary slot becomes `Allow at $11.90 cap` (the
amount left in the budget). Touches show the rate, cap, self-terminate rule and image pin as
chips: `$10.58/hr`, `cap 4h`, `self-terminates`, `image pinned`. Example: `okc bf16 proj`
launching 1×H200 for the bf16 projection bench.

### variant C: irreversible (hard class)

Visually distinct and slower to dismiss, on purpose:
- `danger` border at 60%, 1.5px; the lead glyph is ⚠ in `danger`; the title says what it
  destroys: "delete a worktree".
- A **can't be undone** line comes first in the rows, in `text` (not red: red text fails
  contrast in light mode, the border and glyph carry the colour).
- Touches are counted, not listed: `2.1 GB · 412 files · 3 uncommitted changes · branch not
  pushed`. Anything that would be lost and exists nowhere else is a `danger` chip.
- The trail ends in `never-delegable: deletes outside scratch → you`. No chief, no grant.
- **Deny is primary** (frog's take is deny by default for hard classes unless the agent proves
  the data is elsewhere). Allow is a secondary button with `danger` text that says what it does
  (`Hold to delete`), fills over **1.2 s** while held, and cancels on release. No keyboard
  shortcut; ⌘↩ does nothing on this card. No `Always…`.
- It never collapses when you click elsewhere, never auto-scrolls away, and in notifications
  it has no Allow action (open only).

### answered

The card folds into one line (`motion.panel`) with the choice and its consequence:
`allowed once · ssh started · ↺ Undo` and Undo stays for `motion.toastDwell` (4 s). Allows wait
for that grace before the call is sent, so Undo is honest (it's not undo-after-effect). Irreversible
allows skip the grace: the hold already was the grace. Denials show the note if there was one.

### the digest: Cam's weekly approvals roll-up

The roll-up from delegation.md, as a page in the inbox (`Week` tab) and as one Monday notification.
It's a receipt for trust, read by exception:

- **headline stats**: calls checked, auto-allowed (pass 1 + context pass), chief decided, reached
  you, against the target **≤5 a day** (≤35 a week). A day bar chart with the 5/day line.
- **what reached you**, by class: each row is the class, count, how you answered, median wait.
- **frog suggests**: grants that would have covered what you allowed repeatedly ("you allowed
  `ssh-scratch` for okc workers 4 times, all on pods they made · Grant to okc manager"), and
  grants that went unused ("dg7 unused 3 weeks · Revoke"). One click each, never a sheet.
- **near-misses**: calls a grant blocked and why (the parser's reason), so silence stays
  trustworthy.
- **the chief's calls**: count by class and a link to the audit stream, with Undo where possible.

## 2. waiting on you: the inbox

### the view

A main-area view (⌘⇧0), not a popover: you work through it. It has two tabs: **Now** and **Week**
(the digest).

**Now** is grouped **by manager**, because Cam thinks in managers and answering one manager's
cluster keeps the context loaded. Group headers show the manager's monogram, name, state glyph,
and a summary (`okc manager · 5 workers · 2 asks`). Groups are ordered by their worst consequence
(irreversible, then spend, then blocking, then decisions), then by age.

One strip sits above the groups: **costing money now**, only for items where waiting itself
costs something (a pod billing while its owner waits, an orphan over its cap). It holds at most
two rows, and it's gone when nothing is billing. This keeps background §2's "costing money first"
without breaking the manager grouping.

**Each row** is the ask in one line (components §3's inline row): lead glyph by weight · who ·
wants · the consequence chip (`$10.58/hr`, `2.1 GB, can't undo`, `blocks 2 workers`) · age ·
the first button inline. ⏎ expands the row to the full card in place; ⌘⏎ takes frog's take
(not on irreversible rows). j/k move; e escalates or asks why. Answered rows collapse with
Undo for 4 s, then leave. Effects of one cause fold into one row (a dead manager is one row,
with "3 workers orphaned" as its chip).

**Kinds that land here:** permission cards, `Ask` questions, the chief's decisions relayed for
Cam (rendered as button rows, per Cam's rule that every decision is clickable), dead or orphaned
owners holding money, caps at 80% and when they act. **Never here:** finished jobs, child
reports, notices.

### the empty state

FrogFace 96, mood `working` when anything runs (else `idle`), and:

> everything's handled
> frog is working on 8 sessions · the chief decided 4 today · 212 allowed on their own
> [See this week]

(The brief's "3 sessions" is the shape; the count is live, and the mockup uses the sidebar's 8.)

Numbers come from the ledger and the roll-up counters. When nothing runs: "everything's handled.
nothing's running." The suggestion card from components §11 is dropped: the empty inbox shouldn't
invite work.

### notification entry points

All follow background §2's rules (60 s waited and not on screen; same cause once per 10 m; more
than 3 fold into one).

| entry | shows | actions |
|---|---|---|
| macOS notification | who · wants · consequence chip | routine: Allow once, Deny. spend: Open. irreversible: Open only |
| long-press / expanded | `QuestionBody` with the trail and touches | same as above |
| menu bar face | mood = aggregate (working, waiting, sad); count; the first 5 asks | each opens its row in the inbox |
| dock badge | the count of asks, nothing else | — |
| toolbar pill (another session) | `2 waiting elsewhere` in `warning` | opens the inbox |
| sidebar | a `waiting on you · 3` row on top; ✋ on each session row that has one | opens the inbox, filtered to that session |
| phone / watch | same as the notification | same |

### 2.4 the seam with the sidebar refactor

The inbox owns the list of asks; the sidebar only points at it. What this design needs from the
refactor, and nothing more:
1. a fixed top row `waiting on you` with the count (warning), above the session tree.
2. the session tree keeps the manager → workers nesting, with one status glyph per row (the
   background vocabulary), and a `+18 done` collapse row under each manager for idle,
   finished workers.
3. a failed worker stays visible above the collapse with its red dot and a one-line why, so the
   inbox's "dead / orphaned" row and the sidebar agree.
4. selecting a session that has asks shows them pinned at the top of its transcript, the same
   card as the inbox (one component, two places).

The mockup uses Cam's screenshot's shape: the okc manager with its 5 live workers (attn decode,
serving patch, decode layer, bf16 proj, prefill layer), one red failed row, and the `+18 done`
collapse.

## 3. session header and badges

The header is today's toolbar capsule (`ActivityViewer`) plus one row of context under it. Two
lines, both one-line, both quiet:

**line 1 (toolbar):** org breadcrumb on the left · the activity capsule in the centre (unchanged)
· on the right, the cost so far and the model readout.
- **breadcrumb**: `chief › okc manager › okc bf16 proj`, callout, muted, the current session in
  `text`. Each crumb opens that session. Workers show their chain; a top-level chat shows its
  folder.
- **cost so far**: `$4.12` in mono digits, hover splits it by model and shows tokens and energy
  (what `readoutHelp` has today). For a manager it says `$4.12 · team $31.70` (its workers
  included). Signed-in frog cloud sessions say tasks instead: `3 tasks`.

**line 2 (context row, caption):** worktree and branch chip (`muse_bf16_proj · frog/bf16-proj`),
session age (`3h`), mode (`auto`), then the **badge row**.

**Degraded badges** (from `Status.degraded`): one chip per kind, not a `+1` count, because each
has a different fix. Neutral `surface` fill, `line` border, a 6 px `warning` dot, words from the
engine's `what`. Click opens a popover with the `why` and **one fix**:

| kind | chip | popover fix |
|---|---|---|
| `text_tools` | text tool calls | `Try native tools again` (resets the probe) |
| `model` | on glm-5.3-flash, not opus | `Switch back to opus` (an `Op::SetModel`, clears the flip) |
| `classifier` | classifier down · asking more | `Use on-device check` (Apple fallback) or the status of the fallback |

Today's `DegradedBadge` uses an orange 14% fill: that's the brown the tokens rule out, and the
`+1` hides the second fix. Both change. When three or more are degraded, the session row in the
sidebar gets the warning dot too.

**The return state.** When you open a session that had events while you were away, one strip
sits under the header for one look (it fades after you scroll or 10 s):

> while you were away · 2h — 3 things waited for you: 2 approvals (chief took 1, you took 1 on
> your phone), 1 answer done · [Show]

Show scrolls to the first one; each is marked in the transcript with a small ✋ in the gutter.
It's derived from the ledger, so it agrees with the inbox. It's nothing when nothing waited.

## 4. model picker v2: choosing a colleague

The picker stops being a list and becomes the lineup. Same popover anchor (composer pill and the
header readout), 460 wide.

**Auto** comes first, as a wide card: the FrogFace in all three accents, `auto` and the rule
in one line, plus what it did this week.

> **auto** · dart for most steps, leaps to tree when a turn is hard, to bull for long plans.
> never puts dart in charge of other agents. last 7 days: 80% dart · 15% tree · 5% bull · ~25¢ a task

The "never puts dart in charge" rule is the chief eval's safety result (dart: 3 safety fails, in
unverified-merge, dirty-prod-server and permission-laundering). Signed out, auto means this mac
only: sign-in adds, never unlocks.

**The lineup**: three colleague cards side by side, each with:
- the model's FrogFace (dart, tree, bull weights and accents) and its name in its accent
- a role line: dart "quick hands · edits, tests, renames"; tree "steady · features, reviews,
  runs agents"; bull "deep · hard bugs, long plans"
- **quality**: the chief eval score as a 0–10 bar: **dart 2.6, tree 6.3, bull 7.1**, with
  safety fails as a `danger` chip only when there are any (`3 safety fails`). Hover: "chief eval
  · 10 org scenarios · opus-graded · 2026-10-23"
- **cost a task**: **dart ~18¢, tree ~37¢, bull ~$1.10** in credit (= 1×, 2×, 6× a dart task).
  Signed in on a plan this reads in tasks (`1 / 2 / 6 tasks of credit`). Derived below.
- speed, from tang where measured (dart 226 tok/s single-stream on 1×H200), else "—"
- selected: `accent` ring at 2 px and the checkmark; leapt this turn: `leapt to bull` caption

**this mac** under the lineup, in today's `ModelSections` order and rows: qwen3-4b (ready, free,
speed), Apple on-device, suggested downloads. Local models show **free** as their cost and
"not in the chief eval yet" (faint) as their quality, honestly, until they're scored.
**Your servers** and **other clouds** follow, as today, collapsed to one line each when closed.

Footer: `Manage models…` (Settings → Models) and the frog cloud line from accounts-ux (tasks left).

Auto's ~25¢ is the margin model's 80/15/5 routing over those three. **Where the cost numbers come from.** The margin model (zest `docs/pricing/blended-margin-model.md`
@168bd7d) card prices × the master plan's task shape (~800k tokens in at 79% cached, 30k out):
dart 168k × $0.60 + 632k × $0.06 + 30k × $1.50 = $0.18; credit weights 1× / 2× / 6× give tree
$0.37 and bull $1.10. The margin model still names the middle tier `glass` and maps bull to
GLM-5.3; the current mapping (tree = GLM-5.3-Flash, bull = DeepSeek-V4.1-Flash, Cam 2026-10-24)
is what the picker shows. Re-run when the weights are re-set.

## 5. build order (no dates)

1. one `Ask` record: `class`, `trail`, `spend`, `hosts`, `reversible`, `asked_at` on
   `PermissionRequest` (engine `ApprovalCard` already has trigger, touches, risk, recommendation).
2. approval card v2: the three weights, the trail, the four verbs, hold-to-allow, the answered fold.
3. header: breadcrumb, cost, the badge row (each chip with its fix), the return strip.
4. inbox Now: manager groups, the money strip, inline answers; ListApprovals is the data source.
5. notifications, menu bar, dock, the sidebar seam (with the sidebar refactor).
6. picker v2: auto card, lineup cards, eval and cost data from the catalog.
7. Week tab: the roll-up, suggestions, near-misses.

## 6. decisions for Cam

1. **the fourth verb at the top**
   1. `Ask why…` sends the card back to the agent for context (recommended)
   2. `Send to chief` for a second opinion, even after the chief fell back
   3. no fourth verb for Cam: three buttons
2. **how irreversible cards resist**
   1. hold 1.2 s on a `danger`-text secondary button, no shortcut (recommended)
   2. type the target's name to confirm (GitHub style)
   3. same as other cards, only the red border
3. **inbox grouping**
   1. by manager, with a `costing money now` strip on top (recommended)
   2. by consequence (money, blocking, decisions), as background §2 said
   3. one flat list by age
4. **cost a task in the picker**
   1. credit dollars (~18¢ / ~37¢ / ~$1.10), tasks when on a plan (recommended)
   2. tasks of credit only (1 / 2 / 6)
   3. card $/M tokens, as the API page shows
5. **auto never puts dart in charge of other agents**
   1. yes, a hard routing rule until dart 2 clears the chief eval's safety cases (recommended)
   2. a soft default the user can override per session

## shots

`ui-surfaces-shots/`, each in `-dark` and `-light`: 01 card-routine · 02 card-spend · 02b
card-spend-over · 03 card-danger (mid-hold) · 04 card-answer (always… scopes, folds) · 05 inbox ·
06 inbox-empty · 07 digest · 08 notify · 09 header (badge popover) · 10 header-return · 11 picker ·
12 picker-hover (signed out). Digest numbers are illustrative; org names, eval scores and costs
are real (sources above).
