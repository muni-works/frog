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
