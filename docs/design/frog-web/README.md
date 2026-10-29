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

## The web app as built (supersedes the boards where they differ)

The boards are the starting point. The shipped web app (`apps/web`) has moved on:

- **No borders.** Nothing is outlined: not the sidebar, title bar, inspector, composer, message bubbles, cards, chips, menus, buttons, fields or code blocks. Surfaces separate by fill (`--bg`, `--card`, `--well`, `--hover`) and, for floating menus, a soft shadow. Something that used to be outlined sits on a fill instead: chips and bordered buttons on `--hover`, fields and code on `--well`, cards on `--card`. Focus shows as a soft frog-green glow (`--frog-pad`), not an outline. Two exceptions: the thin left rails that nest content (quotes, tool output, reasoning), and status glyphs drawn as strokes (spinners, rings).
- **Sidebar:** New session and Search (⌘K), then sessions under days (Today, Yesterday, Previous 7 days, Previous 30 days, Older). Rows are two lines: the title flush left, with the PR and status ("Running", "Needs you", "Failed", "Paused") or a dot for a turn that ended since you looked on the right, then what it's doing, its last reply, or its repo, turns and model. Compact (view options) makes them one line. Rows carry no timestamps; view options also group (date, repo, none), sort (activity, created, name) and show archived. "Sleeping" is never shown: it's every idle cloud session. Sandboxes that never started fold into "N couldn't start" with Clear. There is no "Needs you" section and no Repos, Routines or Skills.
- **Signed out:** no sidebar. The landing is the new-session page (the pond, three benefit cards, trust lines) with the full composer. Send signs in with GitHub and starts the conversation on return; with nothing typed, the send button reads "Sign in".
- **Composer:** the same component signed in and out. Suggestion chips float on one line above it: cold starts signed out, repo tasks signed in, and the model's `Next` suggestion in a session.
- **Loading** is the conversation's shape shimmering, with no caption.
- **Pricing** is per token in dollars; nothing says "tasks". Speed is tokens per second.

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
