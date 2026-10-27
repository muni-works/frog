# the premium shell: frog's macOS app, redressed to the Claude Code Desktop bar

*product mock-up, nothing built · open `mockup.html` in a browser (the app window is the second screen)*

Cam, 2026-10-27: "let's discuss how to design the app to be more premium like claude code desktop."

This spec covers the **shell** — sidebar, top bar, transcript frame, composer, inspector. The
**content** layer (outcome cards, claims, the attention queue, inline figures) already has its own
specs in flight: `frog/review-ux:design/review-ux/README.md` and
`frog/diagram-ux:design/diagram-ux/README.md`. Those specs say what frog says; this one says how
the room around it looks and feels. Where the two meet (the outcome card on the transcript's
surface, the attention queue in the sidebar), this spec defers to them and restyles only.

The reference is Claude Code Desktop's design language, from Cam's screenshot:

> three-pane shell; a narrow dark sidebar with grouped nav (New, Search, Projects [beta],
> Artifacts, Scheduled, Customize) then session history bucketed by time (Scheduled / Today /
> date buckets) with live status dots and nested-session disclosure ("3 nested sessions" under a
> parent with a git-branch icon); a clean transcript on near-black in a centered ~720pt column;
> user messages right-aligned in compact gray bubbles; agent activity as quiet single-line status
> rows ("Running a command · 11s"); a top bar with session title + env provenance ("Started on
> this computer · muni · Save as environment"); a bottom composer with attach/queue hints
> ("⏎ to send, ⌘⏎ to queue for later"), mode selector (Auto), model picker (Opus 5.5 · Low
> effort) + voice; a footer account pill (Cam · Max).

The whole thing reads **calm**: lots of negative space, one accent, typography first, no chrome
noise.

---

## (a) side by side: what claude code desktop gets right that frog doesn't

Frog's bones are already good — the 720 measure (`TurnSpace.measure`), prose activity lines,
state color confined to glyphs, hover-revealed actions are all in the code today. The gaps are in
*what the shell chooses to show at rest*. Eight concrete ones, each named against the code:

1. **Env provenance in the title bar.** Claude: "Started on this computer · muni · Save as
   environment" sits quietly in the top bar of every session. Frog's provenance is a
   `navigationSubtitle` "project · branch" (`WorkspaceView.swift:623-627`) that competes with a
   glass **ActivityViewer capsule** in `.principal` (`WorkspaceView.swift:536-543`) carrying the
   activity line, model pill, speed, degraded badge and an others-count — a busy instrument panel
   where Claude has a sentence. The fix: the capsule's *content* moves into the transcript as the
   live status row (§c.2); the title bar carries title ▾ · env line · git state (§c.4).

2. **Queue-for-later as a first-class affordance.** Claude states the verb permanently:
   "⏎ to send, ⌘⏎ to queue for later". Frog's queueing **exists** (Return while busy queues;
   `QueuedMessages` rows above the field, `ComposerParts.swift:65-86`) but the only place the
   verb is written is the *busy* placeholder ("Working… Esc interrupts · Return queues a
   follow-up", `ComposerView.swift:300`) — you learn it after you need it, and it disappears at
   idle. The fix: a one-line hint under the field at all times, and queued items styled as a
   quiet strip with a QUEUED tag (§c.3).

3. **Nested-session disclosure as a folded count.** Claude shows "3 nested sessions" as one
   muted line under a parent, with a git-branch glyph. Frog renders the full tree with 14pt
   indents, 18pt monograms, per-row git badges, spinners, and fold lines like "+12 done · 1
   failed" (`AttentionRows.swift`, `Sidebar.swift:465-496`) — the sidebar reads as a dashboard,
   not a list. The fix: children fold to a single "N nested · M running · K yours" line (§c.1).

4. **One accent.** Claude's window has exactly one accent color; everything else is grayscale
   hierarchy. Frog colors by *place*: green bubbles for cloud prompts, blue for local
   (`TurnView.swift:76-79`), purple git badges, orange waiting, red failed, per-folder hue hashes
   (`SessionRows.swift:61-68`) — five-plus hues at rest. The fix: accent `#58cc6f` is the only
   decorative color; **orange means "yours"** and red means failed, nothing else; place colors
   retire into the model picker (§c.0).

5. **Activity as status rows, not live chrome.** Claude renders agent activity as quiet
   single-line rows with one clock ("Running a command · 11s"). Frog is *close* (ActivityLine is
   already prose) but runs **1Hz clocks in three places at once** — the toolbar ActivityLabel
   capsule, LiveStatus, and step clocks (`ActivityLine.swift:184-224`) — and pairs them with
   spinners and mini progress views. One clock, one place: the live row in the transcript (§c.2).

6. **Calm negative space.** Claude's column floats on near-black with generous top spacing and
   nothing hugging the edges. Frog's canvas is `FrogCanvas` white 0.118 (`Motion.swift:67-74`),
   the sidebar is **Liquid Glass over the transcript** (`WorkspaceView.swift:580-593`) so the
   column's left edge visibly bleeds under it, and the composer floats with stacked banners
   above it (up to six: toast, fallback, download, dictation, pending, queued). The fix: flat
   opaque surfaces, one step darker than the canvas, glass retired from the shell (§c.0, §c.3).

7. **Typography-first hierarchy, few sizes.** Claude uses ~4 sizes. Frog uses 9–15pt including
   half-steps (11/11.5/12/13) across sidebar rows, badges, fold lines, and capsule text
   (`AttentionRows`, `GitBadges`). The fix: a 5-step ramp — 14 body / 13 secondary / 12.5
   status / 11.5 meta / 10.5 small-caps — no half-steps between them (§c.0).

8. **Model + effort in one quiet footer control.** Claude: "Opus 5.5 · Low effort" as one
   neutral text control, plus voice, at the composer's edge. Frog splits this across a tinted
   ModelLabel pill, a separate ModePicker, a ContextButton ring, and the dictation mic
   (`ComposerView.swift:314-331`), with cost/speed/energy as *per-turn* footer text
   (`TranscriptView.swift:497-559`) pinned on the last turn. The fix: one "Model · effort" menu
   at the composer; per-turn footers hover-only; run totals in the inspector (§c.3, §c.5).

9. **The account pill.** Claude anchors the sidebar bottom with "Cam · Max". Frog's sidebar
   footer is a generic "Archived (N) · N live" row (`Sidebar.swift:968-990`). Small thing, big
   read: it makes the app feel like *yours*.

## (b) what frog has that claude code desktop doesn't — do not lose

Claude Code Desktop is a beautiful **single-agent chat client**. Frog is an **org console**.
The redesign must calm the shell without flattening what only frog has:

| frog-only | why it can't be lost | where it lands in the redesign |
|---|---|---|
| **Real worktrees with git state** — every session is a branch with ahead/dirty/landed counts (`GitBadges.swift`, `Git.swift`) | Claude shows a flat history; frog sessions *are* git work | Git moves off the rows (noise) into the **title bar** of the open session + the Changes inspector; hover cards stay |
| **The org tree** — managers → workers → agents, live (`SessionBroker.parents`, `AttentionRows`) | Claude has no notion of delegation; frog's whole operating model is the tree | Kept, but folded: one dot per row, children as "N nested" disclosure lines, expand on click (§c.1) |
| **Outcome cards / claims** (`frog/review-ux`) — "verified by something that isn't the author" | Claude has nothing like claims; this is frog's product thesis | Restyled only: one raised surface `#232323`, 12pt radius, no orange glass tint (§c.2) |
| **Approval cards with real policy** (`PermissionCard`, `ItemViews.swift:528`) — why + trigger + risk + recommendation | Claude's permission prompts are bare | Same restyle; orange becomes a 0.5pt signal hairline instead of a 10%-tinted glass field |
| **Local model choice** — blue=local, green=cloud, ModelDownloads, dictation on-device | Claude is cloud-only | Place colors retire from chrome but stay in the **model picker**, the one place place still matters |
| **Inline diagrams** (`frog/diagram-ux`) — figures in the prose, breakdown/ladder kinds | Claude renders Mermaid blocks | Adopted verbatim as the transcript's figure style (the mock uses its case-1 figure) |
| **The pond / brief** (`Pond.swift`, `PondBrief.swift`) — engine-written morning brief with receipts | Claude's "Scheduled" is a timer list | Becomes a **Pond nav item** in the sidebar so it exists outside an empty chat too (§c.1) |
| **Sessions as environments** — drafts, queued messages, pending wakes, scheduled sessions | Claude has "Scheduled" only | Kept; queue strip restyled (§c.3); scheduled gets its nav slot |

## (c) the redesign, pane by pane

### c.0 tokens (the whole change in one paragraph)

```
canvas      #191919   (transcript + main; FrogCanvas dark drops 0.118 → 0.098)
sidebar     #141414   (opaque, one step darker; glass retired from the shell)
raised      #232323   (bubbles, cards, composer field, menus)
hairline    white .065  (dividers)   .11 (field strokes, controls)
text        #ececec / .58 / .34 / .2   (primary / secondary / tertiary / quaternary)
accent      #58cc6f   (AccentColor dark) — running, selected, verified, send, THE accent
signal      #e5a54b   — needs-you only, never decoration
fail        #ff6961   — failed only
type ramp   14 body · 13 secondary UI · 12.5 status rows · 11.5 meta · 10.5 small-caps labels
radii       16 field · 14 window chrome · 12 card · 16 bubble · 7 control
motion      keep Motion.swift (spring 0.42 / snappy 0.22); add ONE status pulse (2.4s breathe)
```

Rules: **state color lives on glyphs only** (a dot, a check, a hairline), never on fills of
things that are not state. Numbers always tabular. One shadow family: the composer field and
nothing else. Progress bars unify to one idiom (accent, 2pt, the existing `WorkingLine` sweep).

### c.1 sidebar (264pt, opaque `#141414`)

Structure top to bottom:

- **Traffic lights row** (52pt) — nothing else on that line.
- **Nav block**: New session (⌘N) · Search (⌘K) · **Needs you (badge n)** · Pond · Scheduled (n).
  "Needs you" replaces the current NEEDS YOU section label — a count in a signal-tinted pill, one
  click from anywhere. Pond moves here from "only on an empty chat" (`PondBrief.swift`), so the
  brief is always one click away. This mirrors Claude's grouped nav (New / Search / Projects /
  Artifacts / Scheduled) one-for-one.
- **Org** (small-caps label): the started-by tree, one row per *session you'd open*: managers,
  workers with live states, and your own top-level sessions. Row anatomy: **one 7pt status dot**
  (accent breathing = running · signal = needs you · ring = unread · red = failed · hidden =
  settled) + title in one weight, 13pt + age (11.5, tabular). No monograms, no per-row git
  badges, no spinners, no fold-count rows in the tree.
- **Nested-session disclosure**: a parent's children collapse into one muted line —
  `⤷ 6 nested · 2 running · 1 yours` — with Claude's git-branch-style glyph. Click expands the
  children in place (the existing `SessionNesting.Counts` already computes these counts,
  `SessionNesting.swift:45-49`; this is pure view work).
- **Today / Yesterday / date buckets** for non-org sessions (chats, one-offs) — the current
  Yours section, regrouped by time like Claude's history.
- **Account pill** pinned at the bottom: avatar · cam · role · "opus 5.5 · local ready" (the
  local-model readiness dot frog already tracks in ModelDownloads, promoted to a glance).

Selection: `rgba(255,255,255,.075)` radius 7 — never accent-tinted; accent stays on the dot.
Width 250 → 264pt; the SessionRail compact strip stays as-is.

### c.2 transcript (the frame; content per review-ux / diagram-ux)

- Column: keep `TurnSpace.measure = 720`, gutter 32; add **top padding 28 → 36pt** and a
  centered "today" date marker at the top, Claude-style.
- **User prompt**: right-aligned bubble, but **neutral raised** (`#232323`, radius 16, 14pt
  text, max 540) instead of place-tinted green/blue (`TurnView.swift:76-79`). The prompt is
  *you*, not *which place served you* — place shows in the model picker and the turn footer.
- **Assistant text**: unchanged (14pt, lineSpacing 6) — already right.
- **Activity rows**: keep ActivityLine's prose; normalize to the **status-row pattern**: icon
  13pt tertiary · one sentence · duration tabular · trailing chevron; running rows get the
  accent pulse + shimmer label, done rows go past-tense tertiary. **Exactly one live row per
  turn, and exactly one clock in the app** — LiveStatus absorbs the toolbar capsule's elapsed
  counter (the capsule itself is dissolved, see §c.4).
- **Cards on one surface**: outcome card, approval card, plan, question — all `#232323`, radius
  12, 0.5pt hairline; the approval card adds a signal hairline (`rgba(229,165,75,.32)`) instead
  of the orange 10% glass tint (`ItemViews.swift:528`). Buttons: primary = accent fill,
  secondary = raised, ghost = text-only. Recommended option first, per review-ux.
- **Figures**: diagram-ux v2 verbatim (no card, point line + headline number, hatched muted,
  accent focus). The mock adopts its case-1 breakdown untouched.
- **Turn footer**: model · cost · speed · Wh move to hover-only everywhere (drop the pin rules
  in `TurnFlow.swift:393-409`); session totals live in the inspector's run section.
- Retire: the mascot + lily-pad chrome from the flow (`TranscriptView.swift:701-783`) — keep it
  in the empty page where it's charming, remove it from live turns where it's noise.

### c.3 composer

- Field: raised `#232323`, radius 16, one 0.5px hairline + one soft shadow; transcript scrolls
  under a 40px fade (already built, keep).
- **Queue affordance**: a persistent one-line hint under the field — `⏎ to send · ⌘⏎ to queue
  for later · esc interrupts` (11pt, quaternary). Queued messages render above the field as a
  quiet strip with a small-caps QUEUED tag and an ✕ to un-queue (replaces
  `QueuedMessages`' clock-icon rows).
- **Controls row**, left → right: + (attach/mention/skill) · **mode menu** ("Auto ▾", neutral)
  · spacer · **model menu**: "Opus 5.5 · low effort" in one control (text color primary for the
  model, tertiary for effort — no place tint) · mic · **send** (accent circle, 28pt).
  ContextButton's ring moves into the model menu's popover (context % is a run fact, not a
  chrome element).
- Banners above the field collapse to **one line max**: pending wakes + queued + downloads
  merge into a single pending strip (PendingEventsStrip already counts them); dictation becomes
  a state of the mic button, not a banner.
- While busy, the live row in the transcript carries **stop**; the send button keeps its glyph
  (Claude's pattern) instead of morphing into a red stop circle.

### c.4 top bar (52pt, hairline below)

Left → right: **title ▾** (rename menu, existing `toolbarTitleMenu`) · **env line** —
`⌘ on this computer · chief · save as environment` (or `on frog cloud · zest` for cloud
sessions; "save as environment" is a stub that opens the existing env/workspace actions) ·
spacer · **git chip** — branch, ↑ahead, dirty dot (the hover card from `GitBadges` survives) ·
terminal toggle · inspector toggle.

The ActivityViewer glass capsule is dissolved: its activity line becomes the transcript's live
row (§c.2), its model pill moves to the composer (§c.3), its degraded badge becomes a title-bar
dot with tooltip, its others-count moves into the Needs-you nav badge. Split panes keep their
numbered headers (`PaneView.header`).

### c.5 inspector (the panes card, restyled)

The floating glass card becomes a **docked third pane** (312pt, `#141414`), Claude-shell
symmetric: tabs Changes / Terminal / Preview at top; below, four sections —

- **worktree chip**: branch · ↑2 ahead · 3 files · +214 −0 (data all already computed in
  `Git.swift` / `GitBadge`);
- **changes**: the existing ChangesInspector file list (M/A pills, green adds);
- **this session**: the claims/outcome checklist mirrored from the card, + "spec committed on
  branch · not pushed" state lines;
- **run**: model · effort · speed · session cost · energy — the per-turn footer clutter,
  promoted to one quiet home.

The collapse-to-pill behavior stays for narrow windows; ⌥⌘0 unchanged.

## (d) build order (smallest first)

| # | change | where | kind | size |
|---|---|---|---|---|
| 1 | tokens file: colors, ramp, radii as constants; swap FrogCanvas dark to 0.098 | `Motion.swift`, `Palette.swift`, new `Tokens.swift` | pure SwiftUI polish | S |
| 2 | neutral prompt bubble (drop place tint) | `TurnView.swift:76-79` | pure SwiftUI polish | S |
| 3 | one clock: delete the toolbar capsule's elapsed counter, keep LiveStatus | `ActivityViewer`, `ActivityLine` | pure SwiftUI polish | S |
| 4 | composer hint line + QUEUED strip restyle (data exists) | `ComposerView`, `ComposerParts.swift:65-86` | pure SwiftUI polish | S |
| 5 | turn footer → hover-only (drop pin rules) | `TurnFlow.swift:393-409` | pure SwiftUI polish | S |
| 6 | sidebar: status-dot column, drop monograms/git badges from rows, fold children to "N nested" lines, account pill | `Sidebar`, `AttentionRows`, `SessionNesting` (counts exist) | mostly polish; grouping query needs `Library` touches | M |
| 7 | nav block: Needs-you badge, Pond item, Scheduled count | `Sidebar` | polish + one Pond fetch path | M |
| 8 | title bar: title ▾ · env line · git chip; dissolve ActivityViewer | `WorkspaceView.swift:529-573` | polish + **engine data**: env kind (local/cloud) on StatusInfo | M |
| 9 | card surface unification (outcome/approval/plan/question on one raised surface, signal hairline) | `ItemViews`, `AskViews`, `TurnView` | polish; **depends on review-ux** claim rendering | M |
| 10 | inspector: docked pane with changes/session/run sections | `PaneArea`, `PaneView`, new inspector view | polish + session totals from `TurnUsage` aggregation | L |
| 11 | mascot retirement from live flow; empty-page only | `TranscriptView.swift:701-783` | pure SwiftUI polish | S |

1–5 and 11 are a weekend of pure polish and would already read as "the calm version of frog".
6–8 are the shell's identity change and need small engine additions (env kind, run totals).
9–10 land with the review-ux build order (its step 2, outcome card read-only, is the natural
host for step 9).

---

## open questions for cam

1. **Prompt bubble**: neutral gray (recommended, the Claude read) vs keeping a *single* quiet
   tint for cloud/local? The tint is real information but it's also the loudest thing in the
   column today.
2. **Sidebar grouping default**: org-first (recommended) vs Claude's pure time-buckets, with
   org behind a filter? Org-first is frog's identity; time-buckets are calmer.
3. **Inspector docked** (recommended, symmetric shell) vs keeping the floating glass card?
   Docked costs window width; floating keeps the "peek" charm.
