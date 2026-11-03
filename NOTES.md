# perf-ui — notes

Branch frog/perf-ui (base e2403715 = origin/main). Cam's profile of the live app: `frog.sessions.watch`
(SessionDirectoryWatcher.scan()) burns CPU idle — 1 Hz full directory scan over
~/.local/share/frog/sessions (1,026 .jsonl + 498 other files, 1.9 GB), plus per-scan
`contentsOfDirectory` + per-URL `resourceValues`, plus String NFC normalization in
`changedSessions` (Unicode._NFCNormalizer in his stack). Every detected change →
`Library.refresh()` → `frog --sessions --all --json` subprocess (1.51 MB output, 0.05–0.09 s
wall) parsed, then filtered with `FileManager.fileExists(cwd)` PER ENTRY (1,026 stats) on the
main actor, gated to ≥1/3 s (listInterval). One commit per unit (`git commit -s`), never push.
Edit tool only for source.

## Measured BEFORE (pid 35423, Cam's install /Applications/Frog.app, 13:36)
- `/bin/ps`: 62.9% CPU while running; chief's idle profile: 39%.
- `sample` (2 s, quiet): main thread 100% pinned in `Workspace.worktreeOwner →
  SessionBroker.checkout` → `String.withFileSystemRepresentation` →
  `UnsafeBufferPointer._decomposed` (NFD decomposition for every fileExists path), plus URL
  parsing (`percentDecode`, `URL.parse`) — 364+302+168+100 samples of 1026.
- Watcher scan (1 Hz): `contentsOfDirectory` (1,524 names) + 1,026 resourceValues (NFC
  normalization of each name) + dictionary Set diff.
- Listing refresh (per change, ≥1/3 s): `frog --sessions --all --json` = 0.05 s wall,
  1,513,334 B out, then decode + 1,026 `fileExists(cwd)` stats on the main actor.
- Subprocess alone measured: `/usr/bin/time frog --sessions --all --json` → real 0.05 s,
  user 0.01 s, sys 0.01 s; output 1.51 MB.

## Plan
1. Checkpoint (this).
2. Watcher: single `getattrlistbulk` enumeration per scan (no contentsOfDirectory, no per-URL
   resourceValues, no NFC compare — file IDs + raw bytes mtime as UInt64), timer 1 Hz → 10 s,
   FSEvents dir source stays (covers creates).
3. Listing: `Library.refresh` keeps a cache of the last listing; refresh only changed ids
   (`frog --sessions --ids a,b,c` — new engine flag) merged into the cache; the full
   `--sessions --all` only when ids unknown or cache empty. cwd-exists filter cached per cwd
   with TTL (folders rarely appear/disappear).
4. Pill (LiveStatus 1 Hz): check it doesn't invalidate views when nothing changed.
5. Builds + tests, after numbers, table here.

## Result

Commits: 56f81eda (checkpoint + before numbers), faa15d40 (engine `--sessions --ids`),
d5f549f9 (watcher + Library), 70243250 (tests). Never pushed.

### What changed
- **Watcher** (`SessionDirectoryWatcher`): the 1 Hz `DispatchSourceTimer` → 10 s. `scan()` no
  longer runs `contentsOfDirectory` + per-URL `resourceValues`: one `getattrlistbulk` returns
  every entry's (name bytes, objtype, mtime timespec, size) in a single syscall; the diff
  compares `(mtime ns, size)` integer words keyed by id — no `Date`, no String compare, so the
  NFC/NFD normalization in the profile is gone. The FSEvents directory source still covers
  creates and renames; the 10 s timer is the belt for appends that emit no event.
- **Listing** (`Library.refresh(ids:)`): the watcher now names WHICH ids changed; the app calls
  `frog --sessions --ids a,b,c --all --json` and merges the rows into the cached full listing.
  A full `--sessions --all` runs only on launch or when the cache is empty. The engine shares
  its `.list-index.json` with the ids path, so an unchanged id costs one `metadata` and a
  changed one re-reads only its own log. The per-entry `fileExists(cwd)` filter (1,026 stats on
  the main actor per refresh) is now a per-cwd cache with a 60 s TTL.
- **Engine** (`session::list(dir, cwd, ids)` + `frog --sessions --ids`): named ids skip the
  directory walk and open exactly those logs; missing ids drop from the index; the index write
  is the same atomic rename as the full walk's.
- **Pill** (fix 3, verification only — no change needed): `ActivityLabel` has no clock
  (`be9adb66`, "premium shell 3"); the pill's `WorkingLine` rides a 1 Hz beat (4c7e0f86); the
  frog was retired from live chrome (43fdec11). `PillChurnBenchmarkTests.testBaseline` on this
  branch: **619 updates/min** (viewer 4, label 595, frog 0, line 20, clock 0) — label bodies are
  event-driven (each streamed step changes the words), the only 1 Hz timeline left is the
  transcript's `LiveStatus` row, and nothing invalidates when idle.

### Before / after (measured, not estimated)
The store: 1,029 .jsonl (+ 374 .live, 127 .json), 1.9 GB. "Old" = Cam's running install (pid
35423, /Applications/Frog.app, release build, ~6.5 h uptime, 796 MB RSS). "New" = this branch,
Debug build with the new engine in Resources, same real sessions dir via a scratch HOME
(~/.local/share symlinked), no windows open. CPU measured as process CPU-time delta over a
timed wall window (the honest idle number; `ps %cpu` is lifetime-averaged and lies):

| metric | before | after |
|---|---|---|
| app CPU, 30 s idle window (6 worker engines streaming) | 37.1% | 13.0% |
| app CPU, second 30 s window | 34.8% | 13.3% |
| app CPU, 12 s window with a fresh session file created | 36.1% | 13.8% |
| watcher queue, samples in a 5 s `sample` (of 5,000) | 450 (9.0% of a core) | 8 (0.16%) |
| one scan, component probe (`oldscan` vs `scan9` on the real store, 5 runs) | 16–22 ms | 5.2–7.9 ms |
| word diff of 1,029 entries (component probe) | — (Date/String compare, NFC in stack) | 0.32–0.37 ms |
| `getattrlistbulk` calls in the app sample's hot stack | 72 samples tos | 2 samples |
| NFC normalizer samples in the app sample | 20 tos | 0 (gone from the sample) |
| listing subprocess (`frog --sessions --all`, release) | 0.10–0.25 s, 1.51 MB out | unchanged (only on launch/cache-miss) |
| listing subprocess (`--ids one-session`) | n/a | 0.03–0.05 s, 599 B out |
| PillChurn baseline updates/min | 3151 → 779 (prior work) | 619 (this branch) |

Sample evidence (5 s `sample`, old vs new):
- old pid 35423: `frog.sessions.watch` queue 450 samples — `contentsOfDirectory` enumeration
  129, Set-init/String-bridge 61, `changedSessions` 44 (all through
  `_stringCompareSlow`/NFC-NFD `_resume`). Plus 72 samples of `getattrlistbulk` at top-of-stack
  (inside CoreServices' own URL machinery) and 20 of `Normalizer`.
- new (pid 57217, /tmp/frog-after3+4): watch queue 8 and 8 samples — `getattrlistbulk` 2, no
  Normalizer, no `_decomposed`, no `percentDecode` anywhere in either sample.

### Honest caveats
- The after app is a Debug build and still shows ~13% CPU with zero windows; ~half of that is
  SwiftUI/AttributeGraph settling (AG::Graph frames in the sample) plus the engine-sidecars it
  hosts — not the watcher, which is now 0.16% of a core. The 37→13 ratio is the like-for-like
  number on the same machine, same streaming load, same wall windows.
- I could not measure keystroke-to-paint: no instrumented harness for it here; skipped rather
  than invented.
- The ids refresh keeps `--all` on the command line (the flag means "search every folder"),
  so an ids refresh still filters by cwd — cheap now (folder cache), correct for attempts
  worktrees.
- Fix-3 verification found nothing left to fix: the pill path's remaining 1 Hz is the
  transcript's LiveStatus row, which is intentional (it shows elapsed seconds), and it stops
  with the turn.

### Verification
- `cargo build -p frog -p frog-engine` clean; `cargo test -p frog-engine --lib` 582 pass, 5
  known-environmental sandbox-class failures (documented class, unchanged by this work).
- `xcodebuild build` (pf-dd, FROG_PREBUILT_DIR=/private/tmp/be-prebuilt2 with the new engine
  copied in, CODE_SIGN_IDENTITY="-") BUILD SUCCEEDED; `build-for-testing` succeeded.
- `xcodebuild test`: SessionDirectoryRescanTests 5/5 (including a real bulk-read vs stat
  check), PillChurnBenchmarkTests/testBaseline passed (619/min printed).
- Sample files kept: /tmp/idle-35423.txt (old), /tmp/frog-after3.txt + /tmp/frog-after4.txt
  (new), /tmp/oldscan + /tmp/scan9 + /tmp/difftest (component probes).
