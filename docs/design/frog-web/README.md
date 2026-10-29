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
- **Open:** onboarding without sign-up, i.e. a guest allowance on web and iPhone. This is under discussion and not designed yet.

## Board index

| Section | Boards |
|---|---|
| 1 · One app on Mac and web | `MacApp`, `WebApp`, `Landing` |
| 2 · Key moments | `WebFlows`, `HardTask` |
| 3 · Signing in | `Main`, `CheckEmail`, `Device` |
| 4 · iPhone, iPad and Watch | `IOSApp`, `IOSFull`, `Tablets` |
| 5 · Account and plans | `WebSettings`, `Plans` |
| 6 · Website | `SiteMacAlt`, `SiteMac`, `SiteDocs` |
| 7 · Dark mode | `*Dark` |
| 8 · Building blocks | `Workspace`, `Composer`, `PromoCard`, `Cards`, `Unify` (early rules, partly superseded) |

The boards need the Claude Design runtime (`support.js`) to render. They aren't standalone pages.
