# Compiled memory in frog

frog's client for tang's GDN memstore (`tang-llm serve --memory-layer N`; tang's
`docs/design/gdn-memstore.md`, "Serve wiring"). Code: `crates/frog-engine/src/compiled_memory.rs`,
wired in `engine/window.rs` (`start_compiled_memory`, `finish_compiled_memory`), `engine/dispatch.rs`
(the `Memory` tool), `engine/project.rs` (tool registration), `crates/frog/src/main.rs`
(`frog memory`).

## Per session

The session id is the `prompt_cache_key` frog already sends with chat requests, and keys the
server's copy of the store.

1. **Probe** (after the context window is resolved, at session start and on a model switch):
   `POST /v1/memory/op {"op":"list"}`, 3 s timeout. 2xx: the server keeps memory. Anything
   else (404 from a server without `--memory-layer`, an error, a timeout): it doesn't. A `list`
   rather than `GET /v1/memory`, because a memory server also answers 404 to a GET for a key
   with no store yet. `list` changes nothing server-side. Not probed: OpenAI's own API,
   non-OpenAI-compatible providers, subagents, hermetic (benchmark) runs, `compiled = "off"`.
2. **Load**: `POST /v1/memory/load` with the project's blob, if there is one. If the server
   refuses it (wrong size, failed audit), compiled memory stays off for the session and the
   blob is left alone, so a later export of an empty store can't overwrite it.
3. **Ops**: each `Memory` call is one `POST /v1/memory/op`. After a `put` or a successful
   `delete`, frog exports (`GET /v1/memory`) and replaces the blob, so a crash loses at most
   the op in flight.
4. **End** (engine shutdown, or a model switch): export and save once more, then
   `POST /v1/memory/end`.

A 409 on export (the store failed the server's audit) keeps the last good blob and raises a
notice; so does any other export failure.

## Text

Store values are token ids below 2^18 and the server accepts only ids; it has no text or
tokenize endpoint, and frog has no tokenizer for tang models. frog stores text one UTF-8 byte
per id: lossless, no tokenizer needed, at roughly 4x the store slots real tokens would take.
`tang-llm memory dump --tokenizer` will show these files as byte-tokens, not text;
`frog memory dump` decodes them.

## The blob

`<data>/memory/projects/<project key>/compiled-memory.blob` (the same per-project folder as
`/remember` notes and the repo map, shared by a repo's worktrees; the global memory folder for a
chat). 786,432 bytes, opaque to frog. Written to a 0600 temp file beside it, fsynced, renamed
over it. At-rest encryption is a follow-up: today it's protected by file mode only.

Only the server that wrote it can read it (it's model state, not a file format), so
`frog memory dump` and `forget` load it into a throwaway server session, read or edit, export
and end it.

## What the server sees

During a session the server holds the store in plaintext (host RAM and the slot's state on the
GPU) and sees every op's name and contents, as it sees the prompt. Without `--memory-ephemeral`
it keeps a session's copy until `end` (which frog sends) or the server restarts; with it, the
copy is zeroed and dropped when the slot is evicted or the session ends, and it's never written
to the server's disk either way. The bearer key sent is the chat request's key, to the same
base URL, so a saved frog cloud key still goes only to its own origin.

## Text memory alongside

`/remember` notes are untouched: same files, same index in the system prompt. The compiled
store's contents are never put in the prompt (that's the point); while it's active, the system
prompt gains one line pointing the model at `Memory`. Without a memory server nothing changes
but one probe request per session.

## Not done

- Tested only against a mock server (`compiled_memory::mock`); no tang server with a memory layer
  was available.
- At-rest encryption of the blob.
- Real tokenization (byte ids cost store capacity); a tokenize endpoint on tang, or text ops
  server-side, would fix it.
- Migrating `/remember` notes into the store, or deduplicating between them.
- Merging concurrent sessions in one project: the last session to save wins.
- Capacity errors from a full store surface as the server's error text, unparsed.
