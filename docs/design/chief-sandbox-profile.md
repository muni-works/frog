# Chief sandbox profile: what sandboxed agents may do

Task 4, 2026-10-22. Evidence: all 47 Bash approval prompts in a day were
`unsandboxed: true` escapes. Top causes: (a) `swift build`/`xcodebuild` failing
under the sandbox ("Invalid manifest … sandbox_apply: Operation not permitted",
surfacing to agents as "swift-plugin-server produced malformed response");
(b) `git fetch` / `git ls-remote` / `gh` needing GitHub over ssh; (c) harmless
config reads (~/.gitconfig, ~/.config/frog/config.toml) blocked alongside real
credentials. This describes what changed in `crates/frog-engine/src/tools/bash.rs`
and `config.rs`, the config snippets for each allowance, the risk of each, and
what still needs approval.

## What changed

### 1. Swift builds (the big one)

**Root cause (verified empirically, not guessed):** SwiftPM compiles
`Package.swift` manifests inside its *own* seatbelt sandbox. macOS rejects a
nested `sandbox_apply` **unconditionally** — an inner `sandbox-exec` fails with
`Operation not permitted` even under a fully permissive outer profile
(`(allow default)` with no denies at all). No profile rule can ever fix this;
it is a kernel-level property of seatbelt.

Two changes:

- **`CACHES` gains `Library/org.swift.swiftpm`** (writable). SwiftPM keeps its
  user-level configuration/security fingerprints there; without it every build
  warns and some plugin flows break. `~/Library/Caches` (manifest cache) and
  `~/Library/Developer/Xcode/DerivedData` were already writable.
- **`swift build|run|test|package` get `--disable-sandbox` appended** when the
  command runs inside frog's sandbox (`adapt_swiftpm` in bash.rs). This is a
  token-level rewrite at command positions only: `echo swift build` or
  `swiftc` are untouched, quoting and spacing survive, and an invocation that
  already passes the flag is left alone. frog's seatbelt profile remains the
  outer boundary — writes stay confined to the project, temp dirs and caches;
  only SwiftPM's structurally-unusable inner sandbox is skipped.

`xcodebuild build` needs no rewrite: it doesn't nest seatbelt for SwiftPM
packages (verified: `xcodebuild build -scheme X -derivedDataPath /private/tmp/…`
succeeds sandboxed as-is, with DerivedData outside the home).

Risk: **low**. The outer sandbox still confines everything the inner one would
have, except cross-process writes to *writable* paths — which the outer profile
already polices. What's genuinely lost is SwiftPM's *stricter-than-frog* inner
policy (it denies network during manifest compilation); manifests are compiled
from the project's own Package.swift, so the attack surface is "the file you
already let the agent edit".

### 2. Git reads over https instead of ssh

`git fetch` / `git ls-remote` / `git pull` against `git@github.com:` remotes
failed: ssh needs `~/.ssh` (keys *and* known_hosts) readable, which the sandbox
must not expose to arbitrary commands. Instead of exposing keys, a config-gated
per-command git config overlay rewrites `git@github.com:` → `https://github.com/`
and uses `gh auth git-credential` as the credential helper — via
`GIT_CONFIG_COUNT/GIT_CONFIG_KEY_*` env vars only, so no file is touched and no
key is ever readable.

```toml
[sandbox]
git_https = true   # default: false
```

It applies only when the command is a git **read** (fetch, ls-remote, pull,
clone, submodule, status, diff, log, show, branch, rev-parse, describe, remote,
worktree) and contains no `push` token anywhere — `url.insteadOf` would redirect
a push's URL too, so the overlay must never see one. `git push` keeps asking
(auto.rs hard rule), unchanged.

Risk: **none for the token with the default sandbox, but public repos only.**
Tested (`sandboxed_git_https_does_not_expose_the_github_token`, frog#61 review):
with `git_https = true` and no `allow_read`/`allow_keychain`, an ordinary
sandboxed command can't get the GitHub token. `gh auth token`,
`cat ~/.config/gh/*`, `security find-{internet,generic}-password` and asking the
helper directly (`gh auth git-credential get`, `git credential fill`) all fail
with "operation not permitted" or "item could not be found". `git_https` never
changes the profile (unit test `sandbox_git_https_adds_no_credential_reads_to_the_profile`).
The flip side: the overlay's helper runs inside the same sandbox, so it can't
read the token either. Private repos fail auth (verified on `ecto/frog`), and
the overlay only helps with public ones.

Don't "fix" that with `allow_read = ["~/.config/gh"]` + `allow_keychain = true`.
That opens the token to *every* sandboxed command (`gh auth token` prints it;
observed in a session configured that way), and seatbelt can't scope a file or
Keychain read to one binary. Private repos need the token held outside the
sandbox: the engine (unsandboxed) answers git's credential protocol for
`host=github.com` only. Even then, any command can run
`git credential fill` and get whatever git's helper returns. So the engine
should hand out a dedicated read-only fine-grained token, not gh's full
`gho_` token. Not built; needs Cam's call. The ssh alternative,
`allow_read = ["~/.ssh"]`, is worse still (private keys readable).

### 3. Default-readable config

A small default read-list joins the profile (after the credentials deny, so
later rules win): `~/.gitconfig`, `~/.cargo/config.toml`,
`~/.gitignore_global`, and frog's own `~/.config/frog/config.toml` **by file
name** — the directory `~/.config/frog` stays denied, so `models.json` and any
`keys*`/`config.d/` a future frog adds stay hidden. Credential paths
(`~/.ssh`, `~/.aws`, `~/.gnupg`, keychains, `*.env`-style files, `.netrc`,
`.git-credentials`, `~/.config/gh`, wrangler/cloudflare dirs) remain denied;
`~/.config/gh` still opens only with the existing
`allow_read = ["~/.config/gh"]` opt-in (plus `allow_keychain` or `GH_TOKEN`).

Risk: **negligible**. These files are non-secret tool config; anything that
could hold a key stays in the deny set.

### 4. Config-gated `allow_write`

New `[sandbox] allow_write` (default: nothing). For shared build dirs and the
chief session's sibling-worktree workflow:

```toml
[sandbox]
allow_write = [
  "~/Developer/.shared-target",
  "~/Developer/*/.claude/worktrees",
  "~/Developer/*/.frog/worktrees",
]
```

`~/` expands; paths canonicalize where they exist. Seatbelt gets them as
writable subpaths; bubblewrap binds them writable. Off by default — nothing
widens unless configured.

Risk: **medium, user-chosen**. A sandboxed command can write (and delete) in
those paths. The list above is what the chief session needs; anything narrower
is better. Note the entries don't include `*` globbing in the implementation —
seatbelt subpaths are literal prefixes, so list each worktree root explicitly
(the snippet shows the intent; use real paths, e.g.
`~/Developer/frog/.frog/worktrees`).

### 5. gh reads

No code change: `gh api` / `gh run view` already work sandboxed with the
existing opt-in from the frog docs —

```toml
[sandbox]
allow_read = ["~/.config/gh"]
allow_keychain = true   # gh keeps its token in the login keychain
```

or with `GH_TOKEN` in frog's environment (recommended: no keychain exposure;
the ignored test `gh_auth_status_works_with_the_opt_in_config` covers both).

## What still needs approval (unchanged)

- `git push` — auto.rs hard rule, and the https overlay never sees a push.
- Writes outside the project, temp dirs, caches and `allow_write` paths.
- Reads of credential paths not opted in via `allow_read`.
- `unsandboxed: true` for anything genuinely needing the world (installs,
  system settings).

## Tests

`cargo test -q -p frog-engine sandbox` — profile-generation and rewrite unit
tests (new rules present, every SECRETS path still denied, allow_read never
writable, `adapt_swiftpm`/`git_https_applies` selectivity) plus the two
existing confinement tests. `-- --ignored` adds five real smoke tests, all run
and passing on this machine (macOS 26, Xcode 17 / Swift 6.4):

- `sandboxed_swift_version_works` — `swift --version` sandboxed.
- `sandboxed_swift_build_works_with_the_inner_sandbox_disabled` — cold manifest
  cache; proves plain `swift build` fails sandboxed and the engine's rewrite
  builds.
- `sandboxed_git_ls_remote_https_works` — `git ls-remote https://…` sandboxed.
- `sandboxed_git_ls_remote_ssh_becomes_https_with_git_https_config` — ssh URL
  resolves over https with `git_https = true`, no `~/.ssh`.
- `sandboxed_git_https_does_not_expose_the_github_token` — with `git_https`
  on, six token probes find nothing; public ls-remote still works
  (`FROG_PRIVATE_REPO=owner/repo` also prints the private-repo result).

All smoke tests spawn the real seatbelt profile via `run()`, so they can't be
run from inside an already-sandboxed frog session (nested `sandbox-exec`
always fails; see root cause above) — run them unsandboxed.

One caveat: `xcodebuild` smoke coverage is manual (schemes are per-project);
the verified sandboxed command was
`xcodebuild build -scheme SwiftPkg-Package -destination 'platform=macOS' -derivedDataPath /private/tmp/sandbox-dd`
on a scratch package, **BUILD SUCCEEDED**, DerivedData deleted after.
