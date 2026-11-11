# Frog: design review boards

This folder is a snapshot of the "Frog · design review" canvas. It's the source of the boards that show Frog across Mac, web, iPhone, iPad and Watch. The live canvas is a private Claude Design artifact (https://claude.ai/artifact/JHEhMHTcvzY2NEzubmeuxp). These files are a copy so the design ships with the code.

Each `*.dc.html` file is one board. `canvas.json` holds the layout. `ds/frog/` holds the Frog tokens and components the boards use.

## Decisions these boards encode

- **One app, everywhere.** The Mac app and the web app share one window: `Workspace.dc.html`, with a `platform` of `mac` or `web` and a `scene`. It has a sidebar with standard top links (New session, Search, Repos, Routines, Skills), then "Needs you" with inline Allow and Deny, then sessions grouped by repo with status symbols. The middle is the conversation. The inspector has Changes, Terminal and Preview tabs.
- **One composer**, `Composer.dc.html`, ported from the Mac app's `ComposerView.swift`. The "+" menu holds attach, mention and skill. A chip shows where the session runs. A model pill sits next to it. A context bar above it shows the repo, branch, a PR bound to the session with its checks, and the changes with Commit or Push.
- **Where a session runs, per platform:**
  - Mac: this Mac or Frog Cloud.
  - Web: Frog Cloud only. The web is cloud-only, and every session gets its own sandbox.
  - iPhone and iPad: Frog Cloud first, a paired Mac second.
- **Cloud sessions belong to the account**, so they show up on every device. Local Mac sessions stay on the Mac.
- **frog.toys opens straight into the app.** Marketing lives at /mac. `SiteMacAlt` is the proposed /mac. `SiteMac` is the current page, with the atom story.
- **iPhone is a full app, not a remote.** It works straight from the App Store. Starting from the composer is the default; voice from anywhere is a stretch goal.
- **Removed:** race, the house screen on iPhone, and the $0.50 trial. $5 of credits on sign-up is the only free offer.
- **Dark is the default.** Every board renders dark, and each has a theme switch to view it in light.
- **Open:** onboarding without sign-up, i.e. a guest allowance on web and iPhone. This is under discussion and not designed yet.

## One look (Mac and web), decided 2026-11-11

The Mac app and the web app are one design. Where this section and "as built" below differ, this wins.

- **One token source.** Colours (dark and light), radii, type sizes, spacing and fonts live in [`design/tokens.json`](../../../design/tokens.json). `node design/generate.mjs` writes `apps/web/src/tokens.css` and `apps/FrogKit/UI/Basics/Tokens.swift`; tests on both sides (`apps/web/test/tokens.test.ts`, `FrogTests/TokensTests.swift`) fail if either drifts. Nothing else sets a palette value.
- **Surfaces:** dark page `#000`, sidebar and inspector `#0a0a0a`, cards, bubbles and composer `#121212`, wells `#1a1a1a`, hover 7% white. Light: `#fff`, `#fafafa`, `#f4f4f4`, `#ececec`, hover 5% black.
- **Frame:** the Mac's inset rounded sidebar panel (`#0a0a0a`, 12 px radius, 8 px margin) on a true-black page.
- **Session rows:** status on the right (Running with a breathing dot, Needs you, Failed, PR); the second line is what it's doing or its last reply; no timestamps; a green dot for a finished turn you haven't seen.
- **Title bar:** the title and a ⌄ menu (Rename, Archive, Delete); no folder line; the inspector toggle on the right.
- **Transcript:** your message in a right-aligned bubble. Activity lines are icon + verb + mono argument ("Read `x`", "Ran `cmd`", "Edited `f` +6 −3") with a › disclosure. Thinking is one quiet line with a breathing dot. Ask cards put the command in a well, with Deny and Allow ⌘↩.
- **Composer:** + and send (a green circle) inside the box; the Mac adds the mic inside too. Placeholder "Reply to Frog, @ a file, ! a command". Below it: mode, then where it runs (Mac: a device chip, "on mew · 58 tok/s"; web: "Frog Cloud" and a repo pill), then the model and the ring on the right.
- **Inspector:** one panel with Changes, Terminal and Preview tabs.
- **Copy:** "Frog", capitalised.
- **Still to converge:** text and state colours. The Mac uses translucent text (`text`, `textSecondary`…) and `signal`/`fail`; the web uses solid `fg`/`muted`/`faint` and `notice`/`warn`. Both sets are in the JSON so each app keeps rendering as today; pick one set and delete the other.
- **Proof:** [`docs/design/parity`](../parity/README.md) renders one fixture session in both apps at the same size, side by side.

## The web app as built (supersedes the boards where they differ)

The boards are the starting point. The shipped web app (`apps/web`, live at frog.toys) has moved on. This section is the source of truth.

### Look

- **True black.** Dark (the default) is `#000`, like the iPhone app. Surfaces step up from it, never down: sidebar and inspector glass `#0a0a0a`, cards, bubbles and the composer `--card` `#121212`, code and fields `--well` `#1a1a1a`, hover a 7% white wash. Light mirrors it: `#fff` page, sidebar and inspector `#fafafa`, cards `#f4f4f4`, wells `#ececec`.
- **No borders.** Nothing is outlined: not the sidebar, title bar, inspector, composer, bubbles, cards, chips, menus, buttons, fields or code blocks. Surfaces separate by fill and, for floating menus, a deep soft shadow with no ring. What used to be outlined sits on a fill: chips and bordered buttons on `--hover`, fields and code on `--well`, cards on `--card`. Focus is a soft frog-green glow (`--frog-pad`). The only lines are the thin rails that nest content (quotes, tool output) and status glyphs drawn as strokes (spinners, rings).
- **Type: IBM Plex.** Plex Sans for the interface and replies, Plex Mono for code, diffs, tool arguments and the terminal (Google Fonts, `display=swap`, system faces as fallback).
- **Colour carries meaning, sparingly.** Frog green for live, added and primary; orange (`--notice`) for needs-you and nearing a limit; red (`--warn`) for failed, removed and over a limit; amber only for the pond's fireflies.
- **Motion is quiet and optional.** Spinners, a shimmer on "thinking", breathing dots and the pond all stop under `prefers-reduced-motion`.
- **Scrollbars** are thin with no track: a soft rounded thumb that firms on hover.

### Layout

- **Sidebar:** the wordmark with view options and the collapse toggle (⌘\), then New session and Search (⌘K, the palette), then the session list. Only the list scrolls, fading at its edges and drawing rows lazily (60 at a time); the header and the account footer (avatar, name, credit) stay put. Sessions sit under days; a row is the title flush left, PR and status ("Running", "Needs you", "Failed", "Paused") or a dot for a turn that ended since you looked on the right, then a second line: what it's doing, its last reply, or its repo, turns and model. No timestamps and never "Sleeping". Compact makes rows one line, and only the open session expands while working. View options group (date, repo, none), sort (activity, created, name), show archived. Right-click: Rename, Archive, Delete. Sandboxes that never started fold into "N couldn't start · Clear".
- **Title bar:** just the title, with a chevron menu beside it (Rename, Archive, Delete) and the inspector toggle on the right. No repo line, no "In Frog Cloud".
- **Inspector:** the sidebar's glass, resizable from its left edge (a bar shows on hover; double-click resets), reopening as you left it. Changes lists files (name, folder, new, +/−) that open to hunks with line numbers and tinted rows; Commit and Open PR show only with changes. Terminal is part of the panel: a quiet header (live dot, shell, cwd, close), the prompt's folder green, a frog-green block cursor.
- **URLs:** `/` is the new-session page; each conversation is `/s/<id>`, so refresh and back return to it.

### Conversation

- **Your message** sits in a bubble on the right. Under it, right-aligned and faint: a clock while sending, one tick on the wire with what it's waiting for ("Sent · waking the sandbox · 4s"), gone once Frog starts. Hover shows ✓✓, when you sent it ("3 minutes ago"), copy and edit. After 45 s with no start: "Frog didn't pick this up · Try again".
- **Frog's reply** is plain Markdown on the page. Its row (copy and retry first, then model, cost, tok/s and time) shows only on hover.
- **Tool calls** read as what they did: an icon per tool, a verb ("Ran", "Read", "Edited", "Searched the web for"; "Running…" with a spinner while live), then the argument in quiet mono. A failed or denied tag on those outcomes; a chevron on hover opens the output.
- **"Thinking"** is a shimmering line with a breathing green dot, never monospace.
- **Stopping short is never silent:** a length limit, a loop or a denied step says why under the turn, with Continue. Compaction leaves a quiet rule ("Compacted · 82k → 9k tokens").
- **Starting a sandbox** is three steps (reserving, booting/cloning, Frog starting) with a timer. **Loading** a conversation is its shape shimmering, no caption.

### Composer

- One component, signed in and out, laid out like Claude's: a single line (+, the text, send) that grows as you write; below it, mode and repo on the left, the model and a ring on the right. Suggestion chips float on one line above it (cold starts signed out, repo tasks signed in, the model's `Next` in a session). Signed out with nothing typed, send reads "Sign in".
- **The ring** fills to whichever is fuller, plan or context, and turns red past the plan. Its popover, as in Claude: plan usage (session and weekly limits with resets), usage credits, context, Compact now. `/compact [focus]` works too.
- **Models:** only those with room for agent work (64k+ context) are offered; each shows its price per M tokens and window.

### Billing

- **Two tiers.** A plan (Pro $20, Max 5x $100, Max 20x $200) includes an allowance every 5 hours and every week; past it, turns pay from credit at the model's per-token prices. No plan means usage pricing only. Settings → Billing shows the plan's bars or the plans to pick, then credit with Add credit ($5–$100, Stripe Checkout).
- **Pricing** is per token in dollars; nothing says "tasks". Speed is tokens per second.

### Signed out

- No sidebar. The landing is the new-session page: the night pond (ripples, lily pads, amber fireflies; click to drop), the frog, a beta pill, three benefit cards, trust lines and the full composer, with the Muni squiggle (orange on hover, muni.works) at the foot. Send signs in with GitHub and starts the conversation on return.
- **Link previews:** `og.png` and a looping `og.mp4` of the same pond (`docs/design/frog-web/og.py`).

## Board index

| Section | Boards |
|---|---|
| Start here | `Unify`: the rules, decisions and what changes per platform |
| 1 · One app on Mac and web | `MacApp`, `WebApp`, `Landing` |
| 2 · Key moments | `WebFlows`, `HardTask` |
| 3 · Signing in | `Main`, `CheckEmail`, `Device` |
| 4 · iPhone, iPad and Watch | `IOSApp`, `IOSFull`, `Tablets` |
| 5 · Account and plans | `WebSettings`, `Plans` |
| 6 · Website | `SiteMacAlt`, `SiteMac`, `SiteDocs` |
| 7 · Building blocks | `Workspace`, `Composer`, `PromoCard`, `Cards` |

The boards need the Claude Design runtime (`support.js`) to render. They aren't standalone pages.
