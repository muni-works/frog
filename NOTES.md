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
- d3ea32a checkpoint 0
- 3dc272c policy ([egress], ~/.config/frog/egress.toml), proxy (token per call), egress.jsonl
- bcb6cfc seatbelt enforce (deny outbound but localhost + DNS), EgressBlocked, allow_hosts/unsandboxed
  always card (even auto/yolo), --worker + header.worker, subagents share parent's Egress
- 928a4c4 digest in the brief + morning notice
- 2c48bf0 app: notice rows, --worker on StartSession, iOS durable
- 1561bbe docs (docs/design/egress.md, reference.md)
Suites: engine 491/0 (8 ignored; a first loaded run had 4 timing flakes, all pass alone and on
rerun); app 348, 2 failures = TranscriptSwitchBenchmarkTests (known, unrelated). Network check
(`egress_listed_hosts_work_over_the_network`, --ignored): git/curl/python reach listed hosts.
Target dirs deleted.

## Deferred
Linux enforcement; WebFetch for workers; ssh/URLSession tools get no network when enforced;
CDN/upload-capable listed hosts.
