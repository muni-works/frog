# One shell: threads, documentation, settings

Frog's window has one shell: a left sidebar and a main area. Today the sidebar only lists
threads. This spec makes the same shell carry two more things, documentation and settings,
on the Mac and on the web, and makes docs.frog.toys that same documentation view served
publicly.

Decided with Cam on 2026-11-16. Not built. Not in 0.6.0.

## The rule

Inside the window, frog draws everything from one spec, and the Mac is native only at the
edges (title bar, menus, system dialogs). The right sidebar already follows this
(`docs/design/inspector`, #379 and #380). The Mac's separate Settings window is the
largest piece of system styling left, and documentation doesn't exist in the apps at all.

## The three modes

The shell is always in one of three modes. The mode decides what the left sidebar lists
and what the main area shows. Nothing else about the window changes: same sidebar width,
same flush column, same type, same tokens.

| Mode | Left sidebar | Main area |
| --- | --- | --- |
| Threads (today) | New thread, the thread list, the footer | The transcript and composer, with the right sidebar |
| Documentation | "Back to app", search, the page list by section | One page |
| Settings | "Back to app", the section list | One section |

The right sidebar (Changes, Terminal, Preview) belongs to a thread. It is hidden in
Documentation and Settings and comes back as it was.

### Getting in

- Two rows at the bottom of the left sidebar in Threads mode, above the user footer:
  **Documentation** (book icon) and **Settings** (gear icon). Icon and label, the same row
  style as a thread row, sentence case.
- Mac: Cmd-comma opens Settings mode in the front window. Help › Frog Documentation opens
  Documentation mode. The `Settings { }` scene in `FrogApp.swift` goes away.
- Web: Cmd-comma already opens settings; it opens Settings mode. The settings overlay in
  `ui/Overlays.tsx` goes away.
- The command palette gets "Documentation" and "Settings", and one entry per page and per
  section.

### Getting out

- **Back to app** is the first row of the sidebar in both modes: a left arrow and the
  label. Escape does the same.
- Going back returns to exactly where you were: the same thread, scroll position, composer
  draft and right sidebar tab. Entering a mode never ends, pauses or hides a running turn;
  the thread keeps working.
- Each mode remembers its last page or section for the life of the window.

## Documentation

### Layout

- Sidebar: Back to app; a search field ("Search docs"); then sections as muted 12px
  labels with their pages as rows under them. The selected page has the selected-row
  style the thread list uses.
- Main area: one column, the reading width the transcript uses. A muted section label, the
  page title, then the page. Previous and next page links at the bottom.
- No right-hand "on this page" list, no version switcher, no platform switch. The app
  knows whether it is the Mac or the web and shows that variant where a page has one.

### Pages for the first version

| Section | Pages |
| --- | --- |
| Start | Install · Your first session · Pick a model |
| Use | Permissions and auto mode · Web search and fetch · Sessions and children · Memory and `FROG.md` · Skills and MCP |
| Models | On your Mac · Your own nodes · Your own keys · Frog Cloud |
| When something's off | No web results · A fetch was refused · A thread just stopped |
| Reference | `config.toml` · Flags · Tools · Changelog |

Sources: `docs/quickstart.md`, `docs/reference.md` (split by its headings), `docs/models.md`
and `docs/releases/*.md`. The three "When something's off" pages are new and short; each
has the same four parts: the short answer, what you'll see, what to do, the setting.

### One source

- Pages are markdown files in the repo under `docs/app/`, one file per page, with a small
  manifest that gives the sections, order and titles. Internal docs (`plans`, `research`,
  `design`, `launch`) are never part of it.
- A page can mark a block as Mac-only, web-only or terminal-only. Unmarked text shows
  everywhere.
- The manifest is `docs/app/manifest.json`: `{"version": 1, "sections": [{"title", "pages":
  [{"slug", "title", "file"}]}]}`, with `file` relative to `docs/app/`. A page's URL and id
  is its `slug`, unique across sections.
- A platform block is the lines between `<!-- only: mac -->` (or `web`, `terminal`; several
  comma-separated) and `<!-- end -->`, each marker on its own line. Blocks don't nest.
- Flags, tools and config keys are generated from the build (`frog --help`, the engine's
  tool list, the config struct) into their pages, with a test that fails when a generated
  page is stale.
- The pages ship inside each build, so the docs in an app describe that app's version. The
  version is shown at the bottom of the docs sidebar.
- Search filters page titles and headings in the first version. Full text later.

### docs.frog.toys

- docs.frog.toys is the web app's Documentation mode, reachable without signing in. It is
  not a separate site and has no theme of its own.
- Every page has a stable URL: `docs.frog.toys/<section>/<page>`. Headings have anchors.
- Signed out, "Back to app" reads "Open Frog" and goes to the sign-in page. Signed in, it
  behaves as in the app.
- Pages must render as real HTML for a first request (for search engines and for link
  previews), not only after the app's script runs.
- The Mac's pages have an "Open on the web" action that opens the same page's URL, for
  sharing.

## Settings

Revised 2026-11-18 from the settings canvas ("Frog settings, one shell", boards 1 to 7): the Mac
and the web show the same nine sections, drawn the same way from one list of rows.

### Layout

- Sidebar: Back to app (esc does the same); then one row per section. No search in the first
  version.
- Main area, capped at 720 (the transcript's measure) and centred like it, 40 above:
  - **Title**: 17/22 semibold, one per page, no icon.
  - **Group label**: 12/17 semibold, muted, 22 above and 4 below; only when a page has more
    than one group.
  - **Row**: label left, control right, 11 above and below, a hairline between rows and none
    after the last. No card behind a row.
  - **Label**: 14/20 regular, sentence case, no colon; says what turning it on does.
    **Description**: 12/17 faint, one or two lines under the label; may link to its docs page.
  - Under 760 wide the control wraps below its label and takes the full width.
- Six controls, frog-drawn from the tokens, no system `Form`, `TabView` or grouped list:
  - **Toggle**: on or off, takes effect at once, green when on.
  - **Segmented**: two to four choices that fit on a line.
  - **Pill menu**: five or more choices, or names that vary in length.
  - **Field**: one short value; saves on return or blur, no Save button.
  - **Button**: bordered, small; red text only for something that can't be undone, and it
    asks first.
  - **Value**: a read-only fact where a control would be, in muted text.
- Only Billing uses cards, for the plan and credit blocks.
- No "new" badges anywhere.

### Sections

| Section | Was | Works on both | On the web, an invitation |
| --- | --- | --- | --- |
| General | General | Notifications | Open files in your editor; Frog on iPhone |
| Appearance | Appearance | Theme, Density, Detail, Playful frog, Frog sounds | none |
| Models | Models, Machines, Lend | Default model, your machines, Frog Cloud | Pair a machine; run models on this computer; rename or unpair; share with other machines (your own keys and servers wait while the Mac hides adding them) |
| Permissions | Permissions | The mode new sessions start in | Work in folders on your computer; use other apps |
| Connections | MCP | The server list and each one's state | Sign in to a server |
| Shortcuts | Shortcuts | Each app's own keys, read-only | none |
| Usage | Energy, and spend and the cap from Models | Spend this week and month, a monthly cap, energy | Measured energy for this Mac |
| Account | the Mac's footer and Billing | Name, email, Sign out, sign-ins, devices and keys | none |
| Billing | Billing | Plan, credit, a code, credit added, prices | none |

Lend folds into Models: "Lend this Mac" was the same switch as "Share with my other machines".

### One list of rows

- `design/settings.json` lists every section and row, in order: id, section, group, label,
  description, control, options, and platform. Both apps read it (the web imports it, the Mac
  bundles it, as with `catalog/local-models.json`), so a setting added once appears on both.
  Each app keeps its own bindings and storage. `apps/web/test/settings-rows.test.ts` holds it
  to this spec.
- **platform**: `both` works on the Mac and the web; `invite` works on the Mac and is an
  invitation on the web; `mac` is about the Mac app itself and never shows on the web; `web` is
  a fact only the web needs (cloud sessions are always sandboxed).
- **notYet**: a row that belongs on a platform but can't work there yet, with the reason. That
  app leaves it out rather than draw a control that does nothing.
- **when**: shown only while the named toggle is on.
- **page**: drawn on a machine's (or a provider's) own page under Models, not on the section.
- **web**: the label and description an invitation uses on the web, where they differ.
- The four permission-mode explanations are the selected mode's one-line description, not
  rows of their own.

### Invitations on the web

- An invitation is a real row: the same label and description as on the Mac (or the row's
  `web` words), never greyed out, no lock icon.
- A section's working rows come first; its invitations sit under one "On your Mac" group label
  at the foot.
- Where the control would be, one bordered pill, "Get the Mac app", the download chip's link.
  When the account already has a Mac it reads "Open in Frog for Mac" and opens
  `frog://settings/<section>`. When the visitor isn't on a Mac (a phone, Windows, Linux) there
  is no pill and the row says "On a Mac".
- Rows about the Mac app itself (pausing agents for updates, lending on battery, pairing a Mac,
  provider model lists, always-allowed commands, config.toml) never show on the web.

### Links

- `frog.toys/settings/<section>` and `frog://settings/<section>` open that section. An old
  section name (`mcp`, `energy`, `lend`) opens the section it became.
- `?settings=account|billing` on the web (Stripe and api.frog.toys land there) still opens
  Settings mode on that section.
- A setting's row can link to its documentation page, and a documentation page can link to
  the setting. Both are plain links between the two modes.

## What stays the same

- The sidebar's width, resize behaviour and collapse on a narrow window or a phone. In
  Documentation and Settings the page list and section list collapse the way the thread
  list does.
- Tokens only. No new colours or type sizes.
- Sentence case, no Title Case.

## Out of scope for the first version

- "Why?" links from transcript rows to a docs page, and frog citing a docs page in an
  answer. Both were considered and set aside.
- The agent loading the docs to answer questions.
- Full-text search, versions other than the running build, translations.
- A per-site allow setting for web fetch. The "A fetch was refused" page stops at "paste
  the link" until that setting exists.

## Order of work

1. **Shell modes.** The mode switch, the two sidebar rows, Back to app and restoring state,
   on both apps. Documentation mode with two placeholder pages proves it.
2. **Documentation.** `docs/app/`, the manifest, the markdown reader on the Mac, the
   route on the web, the pages above, the generated reference pages and their test.
3. **docs.frog.toys.** Signed-out access, stable URLs, first-request HTML, the domain.
4. **Settings.** This spec and `design/settings.json`; then the web's nine sections and
   invitations; then the Mac in three steps: the shell mode and the shared row views, the
   sections moving over, and removing the Settings window.

Each step can ship by itself. Steps 2 and 4 don't depend on each other.

## Done looks like

- Mac and web screenshots of each mode, light and dark, match each other the way the right
  sidebar's do (`docs/design/inspector`), and are checked into `docs/design/app-shell/`.
- Entering and leaving a mode during a running turn loses nothing: a test holds the
  thread, scroll position, draft and right sidebar tab.
- docs.frog.toys serves a page to a signed-out request with the page's text in the HTML.
- The Mac has no `Settings` scene and no `TabView` in settings; the web has no settings
  overlay.
- A stale generated reference page fails a test.

## Open questions

- **Where the web's signed-out docs are served from.** The web app's hosting isn't in this
  repo; first-request HTML may need a build step that renders the pages.
- **Mac window size.** Settings as a mode uses the main window's size. A small window
  makes for narrow settings rows; the minimum window width may need to rise.
