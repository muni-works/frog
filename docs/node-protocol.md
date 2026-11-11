# Node protocol (v2)

The contract between a tang node (`tang-llm serve`) and frog (engine and Mac app) for the
local pool. Plan: [every frog is a node](plans/2026-11-11-every-frog-is-a-node.md). Tracks
build against this document; change it here first, in its own commit.

All bodies are JSON. Binary values are standard base64 (with padding). "Beyond loopback" means
the server is bound to an address other than 127.0.0.1 / ::1.

## 1. Auth

- **Keys.** A node keeps a set of client keys in `<tang cache>/node-keys.json` (mode 0600):
  `[{ "client_id", "client_name", "key_sha256", "paired_at" }]`. Only hashes are stored.
  `TANG_API_KEY` / `--api-key-file` still work and count as one more key.
- **Every route but `/health` and `/pair/*`** needs `Authorization: Bearer <key>` when the
  server is beyond loopback. On loopback without any key configured, no auth (as today).
- **No keyless network.** Beyond loopback with no key configured and no paired clients, the
  server still starts (so it can be paired) but answers every gated route `401` with
  `{"error": "not paired"}`.
- `401` body: `{"error": "<reason>"}`. Reasons: `missing key`, `bad key`, `not paired`.

## 2. Identity

- On first run the node makes an Ed25519 key pair in `<tang cache>/node-identity` (0600) and
  keeps it. Its public key is the node's identity.
- **Fingerprint:** the first 16 bytes of SHA-256 of the 32-byte public key, lowercase hex
  (32 chars). Shown to users in groups of four (`3f2a 91c0 …`).
- `node_id` (existing, random) stays as it is; the fingerprint is what clients pin.

## 3. Bonjour TXT (`_frog-node._tcp`)

`v=2`, adds to v1 (`id`, `kind`, `gpu`, `mem`, `unified`, `key`):
- `fp`: the identity fingerprint.
- `pair`: `1` while a pairing window is open, else `0`.
- `key` keeps meaning "requests need a key" (`1` for every node beyond loopback from v2 on).

## 4. Pairing

A user-visible 6-digit code authenticates a SPAKE2 exchange (RustCrypto `spake2`, Ed25519
group, symmetric identities: `A = "frog-client"`, `B = "tang-node"`; password = the 6 ASCII
digits). Nobody watching or relaying learns the key; a spoofed node can't finish without the code.

**Opening a window** (node side only):
- `tang-llm pair` on the node's machine, or `POST /pair/open` from loopback, opens a window
  for **120 s** and returns/prints `{ "code": "123456", "expires_in": 120, "fingerprint" }`.
  The CLI prints the code large plus the fingerprint. A new open replaces the old window.
- **5 failed finishes** close the window. At most one exchange in flight per window.

**`POST /pair/start`** `{ "client_id", "client_name", "spake": <client SPAKE2 msg> }`
→ `200 { "pair_id", "spake": <node SPAKE2 msg>, "node_id", "identity": <32-byte Ed25519 public key>, "name": <host name> }`
→ `403 {"error":"no pairing window"}`, `409 {"error":"pairing busy"}`.

Both sides now hold SPAKE2 output `K`. Derive with HKDF-SHA256 (salt: none, IKM `K`):
- `k_confirm_c = HKDF(info "frog-pair confirm client")`, 32 bytes
- `k_confirm_n = HKDF(info "frog-pair confirm node")`, 32 bytes
- `k_wrap = HKDF(info "frog-pair wrap")`, 32 bytes

`transcript = SHA-256(client_id || 0x00 || client spake msg || node spake msg || identity || node_id)`

**`POST /pair/finish`** `{ "pair_id", "confirm": HMAC-SHA256(k_confirm_c, transcript) }`
→ `200 { "confirm": HMAC-SHA256(k_confirm_n, transcript), "key_box": <nonce(12) || AES-256-GCM(k_wrap, nonce, api_key, aad = transcript)> }`
→ `401 {"error":"wrong code"}` (counts toward the 5), `410 {"error":"pairing expired"}`.

Client checks the node's `confirm` before trusting anything, decrypts `key_box`, and stores
`{ node_id, fingerprint, key, name }` in the Keychain. The API key is 32 random bytes,
base64url without padding, prefixed `tnk_`. The node stores its hash under `client_id`.

**Un-pair:** `DELETE /pair/<client_id>` with that client's bearer key → `204`. The node can
also drop a client with `tang-llm unpair <client_id | all>`. A client whose key starts
getting `401 bad key` treats the node as un-paired.

**Pinning:** after pairing, a client connects only if the node's `/node` `identity.fingerprint`
matches the stored one; a mismatch shows "this isn't the mew you paired" and stops.
(Mutual TLS on these keys comes later; v2 is HTTP + bearer + pinned fingerprint.)

## 5. `GET /node` (schema 2)

Gated (section 1). Changes from schema 1:
- `"schema": 2`
- `"identity": { "fingerprint", "public_key" }`
- `"name"`: the host name.
- Each entry in `models.loaded[]` and `models.on_disk[]` gains:
  - `"weights_hash"`: model identity across nodes (section 6)
  - `"quant"`: `"bf16" | "f32" | "q4" | "mlx-4bit" | "mlx-8bit" | "gguf-<type>"`
- `kv.prompt_cache_keys` stays, but only behind auth (it was readable by anyone before).

Clients must ignore unknown fields, and treat `schema` higher than they know as "update frog".

## 6. Model identity

`weights_hash` = lowercase hex SHA-256 over, in order:
1. the bytes of `config.json`,
2. for each weight file (`*.safetensors`, `*.gguf`) sorted by file name: the name, `0x00`,
   its size as u64 little-endian, and its first 1 MiB.

Cheap (no full read), stable across machines and download paths, different across quants.
Two nodes "have the same model" iff their `weights_hash` match. The engine's model id for a
pooled model is `node/<weights_hash first 12>` with the display name from the node.

## 7. What the engine does with it (for track B)

- **Placement (D3.5):** for a call on a pooled model: the session's pinned node if it has the
  model and answers; else any paired node with the same `weights_hash`, loaded first, then the
  one with most free memory; else this Mac's tang if it has it; else fail with one line.
- **Failover (D4):** a transport error, `5xx`, or no bytes for 20 s mid-stream: drop the
  partial assistant message (never shown as final), mark the node down for 30 s, and rerun the
  model call from the transcript on the next placement. Tool calls that completed before the
  failed call stay done. One notice item: "mew stopped answering; finishing on this Mac".

### The paired-node store (what the Mac app writes, what the engine reads)

- **`~/.config/frog/nodes.json`**, written by the Mac app after a pairing finishes (atomic
  rename, mode 0600), read by the engine on every poll (so a new pairing shows up without a
  restart):
  ```json
  { "nodes": [ { "node_id": "7950c88d…", "fingerprint": "3f2a91c0…", "name": "mew",
                 "base_url": "http://mew.local:8911" } ] }
  ```
  `base_url` is the server root (the engine calls `<base_url>/node` and `<base_url>/v1/…`).
  Unknown fields are ignored; an entry missing any of the four is skipped.
- **The key** never goes in the file: Keychain, service `frog`, account `node:<node_id>`,
  the same item path frog uses for provider keys (`FROG_KEYCHAIN=off` skips it). Un-pairing
  removes the entry and the item.
- **This Mac's own tang** (`http://127.0.0.1:8911`, loopback, no key, no pin) is the last
  placement and is never listed in the file.

### Engine behaviour in detail

- **Polling.** While a session runs on a pooled model the engine reads `GET /node` from every
  paired node about every 2 s (2 s timeout), and before placing a call when what it has is
  stale. Its view of a node is one of: usable, unreachable, or refused with one line:
  - `identity.fingerprint` ≠ the stored one: "this isn't the mew you paired" (never placed);
  - `schema` > 2: "mew runs a newer tang: update frog"; `schema` < 2: "mew needs a newer tang";
  - `401`: "mew isn't paired anymore".
- **Model ids.** `node/<weights_hash first 12>` (an optional `@<node_id or name>` suffix pins
  the session to that node). `frog --list-models` / the picker list each pooled model once,
  `source: "node"`, with the display name from the node (the checkpoint's last path segment).
- **Placement order:** pinned node → the node the session last ran on → other paired nodes
  with the hash (loaded before on disk, then most `hardware.free_bytes`) → this Mac's tang →
  fail with one line ("no paired node has <model> right now").
- **Failover:** transport error, `5xx`, a stream that ends without finishing, or no bytes for
  20 s once bytes have started (120 s before the first): the partial is discarded
  (`items_discarded`), the node is down for 30 s, and the call reruns at once on the next
  placement with one `notice` ("mew stopped answering; finishing on this Mac"). Each failure
  takes a node out, so with every node down the call ends with one line, not a loop.

### Event fields (where a call ran)

- `TurnEnded.usage.ran_on` and `Status.ran_on`: `{ "node_id", "name", "local" }` for the
  last model call on a pooled model (`local: true` = this Mac's tang, `name` "this Mac").
  Absent for every other provider. The chip reads `Status.ran_on.name`; receipts read
  `usage.ran_on`.
