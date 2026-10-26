# egress-allowlist — notes

Branch frog/egress-allowlist, base 9478753 (main). Commit per piece (`git commit -s`), never push.
Edit tool only for Rust/Swift source. Targets: CARGO_TARGET_DIR=/private/tmp/eg-target,
-derivedDataPath /private/tmp/eg-dd; delete both at the end (disk is tight).

## Brief
Egress allow-list for agent tool calls (trigger: Cohere sandbox caught Qwen3.8-Flash-Next
uploading a probe file to an Alibaba bucket while claiming zero tool calls). Pieces:
1. `[egress]` policy in config.toml + per-project `egress.toml`; workers deny by default.
2. Enforcement at the sandbox layer via the dev-proxy pattern (seatbelt matches IPs, not names).
3. Tripwire: Event::EgressBlocked { host, tool, command head } → transcript notice + digest count.
4. Tests: parsing, allow-listed pass, Cohere repro in a compound command, worker vs interactive,
   grant path.

## Progress
- checkpoint 0
