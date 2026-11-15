# fuzz findings: 2026-11-05

This was a report-only pass on main @ 67b64bd8. Nothing in the code was changed, pushed or deployed. Known issues from `launch-readiness-2026-11-05.md` are left out.

**How the two apps were tested**

- **Web:** driven in the built-in browser against `npm run mock` with `VITE_DEV_KEY=dev` on localhost:5173. The mock is a dev key on a local gateway. No real account was used.
- **Mac:** code reading only. Nothing was built or launched, so there are no cold-start or memory numbers. Mac findings are inferred from code and marked that way.

## top 10

| # | area | cat | finding |
|---|---|---|---|
| 1 | web | bug | a long unbroken string in a user message makes the bubble millions of px wide |
| 2 | web | bug/a11y | Enter during IME composition sends the message (CJK/Japanese input) |
| 3 | web | speed | every stream delta re-renders the whole transcript and re-parses all markdown, about 50 ms per delta at 300 turns |
| 4 | mac | bug | the single-instance hand-off drops the folder when the running copy has no window, and never forwards Finder/Dock opens |
| 5 | web | UX | a stale or deleted session URL (`/s/<id>`) renders a blank pane |
| 6 | web | copy | raw server and HTTP text reaches users: "Couldn't start a sandbox: repo must be owner/name", "Couldn't load sessions: Internal Server Error" |
| 7 | mac | UX | an abandoned sign-in spins for up to 10 minutes with no cancel |
| 8 | mac | copy | sign-in errors are handled three different ways, including raw `localizedDescription` and a silent `try?` |
| 9 | mac | copy | `ProviderID.cloudName = "frog cloud"` (lowercase) is shown as a title in Settings and the model picker |
| 10 | both | robustness | a duplicate turn id renders two live permission cards. Allow on the old card answers the current ask |

---

## details

### 1. long unbroken text blows out the user bubble (web, bug)
- **Repro:**
  1. Paste a long token with no spaces (a URL, base64, a minified line) into the composer.
  2. Send it.
- **Evidence:**
  - Measured `.me` scrollWidth was 3,295,504 px against a clientWidth of 512.
  - `.turn`, `.ask-block` and `.col` all overflow with it.
  - The bubble runs off the right edge of the transcript.
- **Fix:** add `overflow-wrap: anywhere` to `.me`, and probably to `.say` / markdown paragraphs. File: `apps/web/src/app.css:50`.

### 2. IME Enter sends mid-composition (web, bug/a11y)
- **Repro:**
  1. Type Japanese or Chinese with an IME.
  2. Press Enter to confirm a candidate.
- **Evidence:**
  - The composer's `onKeyDown` checks only `key === 'Enter' && !shiftKey && !metaKey` (`apps/web/src/ui/Composer.tsx:301-303`).
  - `TerminalPane.tsx:58` already checks `isComposing`. The composer doesn't. This was inferred from code, not typed with a real IME.
- **Fix:** add `if (e.nativeEvent.isComposing || e.keyCode === 229) return` to the composer and to `AskCards.tsx:28`.

### 3. transcript re-renders fully per delta (web, speed)
- **Repro:** run a long session (hundreds of turns with markdown) and watch it stream.
- **Evidence:**
  - Rendered `Transcript` in the page (dev build) with 300 markdown turns.
  - First render: 85 ms. Each one-char delta to the last message: median 49 ms, p90 55 ms.
  - Nothing in `Transcript.tsx` / `Markdown.tsx` uses `memo` or `useMemo`, and there's no rAF batching of envelopes, so every delta re-parses every message.
  - A prod build will be faster, but it still drops frames well before 300 turns.
- **Fix:**
  - Extract a `memo`'d `Turn` component keyed on the turn object. The reducer already keeps unchanged turns referentially equal (`thread.ts:79`).
  - `useMemo` the `parse()` call per message text.
  - Coalesce envelopes per animation frame in `App.tsx` / `engine/cloud.ts`.

### 4. single-instance hand-off loses the folder (mac, bug, from code)
- **Repro:**
  1. With Frog running and all windows closed, launch a second copy with `-FrogFolder /x`.
  2. Separately, open a folder from Finder or the Dock while Frog is running.
- **Evidence:**
  - `handOff` posts a DistributedNotification and immediately calls `exit(0)` (`apps/macos/Frog/FrogApp.swift:197-208`).
  - The only listener is a window's `.onReceive` (`FrogApp.swift:122-126`), so with no window open nothing receives it.
  - `QuitGuard.applicationWillFinishLaunching` exits without passing any folder (`Model/SessionRegistry.swift:276-286`).
  - Open-URL events are never forwarded.
- **Fix:**
  - Observe the notification at the app level, e.g. in QuitGuard, and open a window when none exists.
  - Have the receiver ack before the sender exits.
  - Route `application(_:open:)` through the same path.

### 5. stale session link → blank pane (web, UX)
- **Repro:** open `http://localhost:5173/s/s_doesnotexist`, or reload after a session was deleted elsewhere.
- **Evidence:**
  - `main.innerText === ""`, and the sidebar says "No sessions yet".
  - `current` is undefined (`App.tsx:117`) and no branch renders anything.
  - The 4004 "This session was deleted." banner only appears while a socket is open.
- **Fix:** when `view.kind === 'session'` and the list has loaded without that id, show "This session doesn't exist or was deleted" with a New session button, or redirect to `/` with a toast.

### 6. raw server text in user copy (web, copy)
- **Repro:**
  1. Send with "No repo" against the mock. You get "Couldn't start a sandbox: repo must be owner/name".
  2. Kill the gateway. The sidebar shows "Couldn't load sessions: Internal Server Error".
- **Evidence:**
  - `GatewayError(res.status, json?.error ?? res.statusText)` (`apps/web/src/cloud/client.ts:51`).
  - About 13 call sites interpolate `e.message` directly, e.g. `App.tsx:247,271,281` and `SessionList.tsx:238`.
  - In prod, a network drop will read "Failed to fetch".
- **Fix:** add one `friendly(e)` helper:
  - 401 → sign in again
  - 402 → out of credit
  - 400 → the specific field
  - 5xx / TypeError → "Frog Cloud is unreachable. Retrying."
  - Keep the raw text in a `title`.
- **Related, dev-only:** the mock gateway still rejects repo-less sessions, while the real gateway now allows them (zest `sandbox/src/router.ts:123`). Update `apps/web/test/mock/mock-gateway.mjs:55`.

### 7. abandoned sign-in spins 10 min (mac, UX, from code)
- **Repro:**
  1. Settings → Sign in.
  2. Close the browser tab.
- **Evidence:**
  - The loopback listener waits 600 s (`apps/FrogKit/Core/CloudSignIn.swift:64`).
  - `signingIn` stays true the whole time (`SettingsView.swift:511`, `UserFooter.swift:72`).
  - There is no cancel.
- **Fix:** show a Cancel button while signing in that cancels the Task and the listener, and shorten the timeout to about 3 min.

### 8. inconsistent sign-in error copy (mac, copy, from code)
- **Evidence:**
  - `UserFooter.swift:78` is friendly.
  - `SettingsView.swift:517` shows raw `localizedDescription` in red. Cancel or timeout gives "The operation couldn't be completed…".
  - `BillingSettings.swift:20` uses `try?`, so failures there are silent.
- **Fix:** one shared mapper. Treat user cancel as no error.

### 9. "frog cloud" lowercase in UI (mac, copy, from code)
- **Evidence:**
  - `apps/FrogKit/Core/Protocol.swift:1412`.
  - Rendered at `SettingsView.swift:539` and `FrogKit/Model/ModelIdentity.swift:23,28`.
  - Tests pin it (`FrogTests/ModelSectionsTests.swift:58`).
- **Fix:** change it to "Frog Cloud" and update the tests.

### 10. duplicate turn ids → two live ask cards (both, robustness)
- **Repro:**
  1. Against the mock, send in a new session. The mock replays a demo turn 1, then your message is also turn 1.
  2. Two "Can I bash this?" cards render with Allow/Deny.
- **Evidence:**
  - Clicking Allow on the older card resolved the current ask.
  - The console logged 29× "Encountered two children with the same key `1`" (`Transcript.tsx`, `<Fragment key={turn.turn}>`).
  - `asking` is chosen by `turn.turn === lastTurn` (`Transcript.tsx:139`), so every turn with that number gets live buttons.
  - The trigger here is the mock, but the reducer should be defensive: after a resume or a compaction that renumbers turns, the same thing happens.
- **Fix:**
  - Key turns by index plus turn id.
  - Pick the live ask by the last turn's index, not its number.
  - Ignore or merge a `turn_started` that repeats a known turn id (`engine/thread.ts:85`).
  - Fix the mock so it doesn't reuse turn ids.

## more (lower impact)

- **mac / copy:** raw errors elsewhere (from code).
  - `CloudSessions.swift:46` falls back to `HTTPURLResponse.localizedString`, e.g. "unauthorized".
  - `ComposerView.swift:831` shows "Couldn't download X: \(error)".
  - `ProviderStore.swift:105` and `Race.swift:108` pass raw text through.
  - Fix: the same mapper as #8.
- **mac / robustness:** the cloud session poll runs every 15 s forever with no backoff and no NWPathMonitor (`CloudSessions.swift:27-35`). Offline, the error string flickers every 15 s. Fix: back off and keep the last good list with an "offline" note.
- **mac / bug:** sending just `!` sends `.shell("")` and sets `busy` (`FrogKit/Model/Conversation.swift:355-360`). Fix: guard against an empty command.
- **mac / a11y:** about 102 `Image(systemName:)` against 17 `accessibilityLabel`s. Icon-only buttons rely on `.help` alone. Fix: `Label(…).labelStyle(.iconOnly)`. Examples:
  - `PreviewPane.swift:71,74,116,139`
  - `WorkspaceView.swift:750,754`
  - `SettingsView.swift:256,301,364,577`
  - `ResumedBanner.swift:34`
  - `ComposerView.swift:153,428`
  - `AttentionRows.swift:143`
- **mac / dark-light:** `ActivityViewer.swift:327-328` uses a fixed near-black gradient in both themes. Check it in light mode.
- **web / robustness:** there's no size cap on the composer. A 500k-char paste rendered in about 78 ms and was sent as-is. Fix: warn above about 100k chars, or offer to attach the paste as a file.
- **web / perf:** the bundle is 261.6 kB JS (83.5 kB gzip) plus 49 kB CSS. That's fine, so nothing to do.
- **web / layout:** works at 375 px with no horizontal scroll. Losing the gateway shows "Reconnecting…" and keeps the outbox message with "Sending · reconnecting to the sandbox", which is good.

## not covered
- Mac: no build or launch, so no cold start, memory, huge paste, cancel mid-stream or mid-turn model switching. The next pass needs computer-use on a dev build.
- Web: no real gateway, so no TTFT and no slow-network throttling. Light mode wasn't checked visually; `app.css` has 3 `prefers-color-scheme` blocks.
