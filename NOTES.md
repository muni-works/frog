# stale-session-id — notes

Branch frog/stale-session-id, base 9478753 (main). Commit per piece (`git commit -s`), never push.
Edit tool only for Rust source. Engine suite: CARGO_TARGET_DIR=/private/tmp/ssi-target
cargo test -q -p frog-engine; delete the target dir when done (disk ~12G free).

## Brief (from Cam's live session, via the chief)
A frog session spammed dozens of identical warning rows all night:
"session won't be saved: creating session 20261026-081219-1b08: File exists (os error 17)",
one per event, while the turn kept running. Two bugs, one root.
1. `new_id()` (session.rs:28): salt = counter from a base = `subsec_nanos ^ pid.rotate_left(16)`;
   `& 0xffff` keeps only the low 16 bits = nanos only — the pid is masked away by the salt mask
   (pids < 2^16 rotate into bits 16+). So two engines started the same second with similar
   nanos can mint the same id. Format `YYYYMMDD-HHMMSS-xxxx`, 4 hex chars.
2. `Log::create` uses `create_new(true)` → on collision `File exists (os error 17)`, once per event
   (`Journal::record`, engine.rs:393-401): create failure leaves `log=None` (retried next event);
   append failure drops the log (`*log=None`) and also retries create next event. Either way the
   turn keeps running, one WARN per durable event, forever, and nothing persists. Subagents
   (store=None) never log.

## Fix plan (3 pieces, smallest first)
a. salt: fold the pid into the low 16 bits, e.g. `next.fetch_add(1) ^ (pid & 0xffff)` … keep
   counter monotonic within a process; keep the format `YYYYMMDD-HHMMSS-xxxx`.
b. `Log::create` on `AlreadyExists`: try `open()` + flock (`Log::locked` retries 200ms, then
   errors once — genuinely in use). Take-over must not write a second header: use
   `append-position > 0` ⇒ existing log (append only), else write header. Skip the header when
   the file has content, and check for a torn tail? — smallest: skip header iff size>0;
   a nonzero file always has its first line header already (fold() rejects a second header).
c. `Journal::record` create failure → set a `dead` flag, emit ONE `Event::Notice` level Warn
   "session log unavailable, running without persistence"; subsequent appends are silent no-ops.
   Clear the `dead` flag in `start_session` (new session or Op::Clear retry-fresh). Notice is not
   durable so emit()'s fallback can't recurse.

## Consumers of the id format (verified)
- Nothing in-app parses id shape (no DateFormatter/regex/split on id in apps/*); Swift side uses
  ids opaquely (file lookup `<id>.jsonl` via header/list), `SessionBroker` uses full ids only.
- Engine: `path()` = `<id>.jsonl`, `live_path` = `<id>.live`, header/list/fork re-home full ids;
  `fold` rejects a second header (b must not append one).
- Other `new_id()` callers (tempdirs, image ids, compare tmp) just need uniqueness; keeping
  shape is fine and preferred.

## Tests (engine, in session.rs + engine.rs test mods)
1. two `Log::create` same id same dir: drop first log → second create opens (flock take-over),
   appends without a second header; while held → clean error once.
2. forced create failure (dir named `<id>.jsonl` in the store): engine emits exactly ONE Warn
   notice; later durable events append silently (assert no repeated warnings).
3. salt: fresh salt derivation reads the pid — assert `salt() ^ (pid & 0xffff)`-style test: two
   ids in one process differ; and expose the salt fn to assert pid mix (unit assert that salt
   for different pid inputs differs, via a `#[cfg(test)]` helper taking pid).

## Progress
- (checkpoint 0)

## Suite
- (pending)
