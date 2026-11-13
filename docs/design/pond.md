# Pond: a calm home for many agents

Pond is Frog's first-class way to run a small organization of agents. The user speaks to one persistent chief window; leads own durable areas; workers do bounded tasks under a lead. The main sidebar becomes an operational roster instead of a history of every conversation. Existing sessions remain the transcript and execution unit.

## User flows

### Start and return

- A global hotkey opens the chief window from anywhere. It floats above other windows, remembers its position and size, and can collapse into a compact pill without ending its session.
- The chief is a normal resumable Frog session with a global brief and memory. It can answer, delegate to an existing lead, or propose a new lead. It does not silently create or authorize external side effects.
- On launch, the chief restores to the previous state. The sidebar immediately shows each lead's latest status and short `now:` line. Activity is streamed into the relevant lead or worker row.

### Delegate and follow work

- The user asks the chief for an outcome. The chief selects a lead by area or proposes one, then starts a worker linked to that lead and gives it a scoped task, context, and allowed tools.
- A lead stays alive across tasks and owns its brief, memory, and worker history. Its row summarizes current focus; expanding it reveals active workers with live progress. Completed workers move into the lead's searchable log and stop occupying the live roster.
- Selecting a lead opens its durable conversation. Selecting a worker opens that worker's transcript. The user can redirect, stop, or resume either session.

### Resolve attention

- A single `NEEDS YOU` strip appears above the leads only when a decision is pending. It contains approvals, merge requests, purchases, and spend-cap requests, ordered by urgency. This strip is the only orange UI surface; status lights use non-orange colors.
- Each item states the requesting lead/worker, the action and its consequences. Tappable decisions return to the chief as explicit buttons, then record the user's choice and receipt. Dismissal is not approval.
- After resolution, the item leaves the inbox and the requesting lead receives the result.

### Review delivery and spend

- Every lead has a compact PR/CI summary. Opening the lead shows checks, diff link, and a merge action when policy permits; merge is an explicit attention item and receipt, not an ambient auto-action.
- Lead-level GPU/token usage is visible with a configured cap and current remaining budget. Workers inherit the lead's cap unless the user grants a scoped override. Reaching a cap pauses new work and raises attention rather than overspending.

## Data model

A session remains a transcript/execution record. Pond adds typed role and ownership metadata, keyed by the existing stable session ID. Do not infer roles from titles or cwd. Parent links are acyclic; a worker has one owning lead. The chief is a special global lead-like session and may coordinate multiple area leads.

```text
PondSession {
  session_id: String                 // existing session ID
  role: chief | lead | worker
  parent_session_id: Option<String>  // worker -> lead; lead -> chief
  area: Option<String>               // stable lead ownership key
  brief_path: Option<PathBuf>
  memory_path: Option<PathBuf>
  state: queued | running | waiting | idle | finished | stopped
  now: Option<String>                // short, refreshed progress summary
  created_at, updated_at
}

AttentionItem {
  id: String
  owner_session_id: String           // lead responsible for resolution
  source_session_id: String          // worker or lead that requested it
  kind: approval | merge | purchase | spend
  state: pending | approved | denied | dismissed | completed
  title: String
  detail: String
  choices: [AttentionChoice]
  created_at, resolved_at
  receipt: Option<String>
}

LeadBudget {
  lead_session_id: String
  period: day | month
  token_cap: Option<u64>
  gpu_seconds_cap: Option<u64>
  spend_cap_microusd: Option<u64>
}
```

Persist role, parent, area, status and summary in a Pond metadata store with atomic updates and schema versioning. Keep the transcript in the existing append-only `<id>.jsonl` log. Store each lead's editable brief and durable memory as plain-text/Markdown files in its own metadata directory; keep their paths in the metadata record. The chief gets a global brief and memory in the same store. Worker logs are not copied into lead memory: the lead can summarize them deliberately, with source session links.

Attention items are durable records, not ephemeral SwiftUI state. Resolution appends an auditable decision receipt, including actor, selected choice, timestamp and affected session. Secrets and provider credentials never belong in briefs or memory.

## Engine and app changes

- Extend session creation/fork APIs with an explicit role and parent/area metadata path. Preserve ordinary sessions unchanged. Validate that parents exist, worker parents are leads (or chief where allowed), and links do not cycle.
- Add a versioned Pond store/API for listing leads, their active workers, status/`now` updates, briefs, memory, budgets, and attention CRUD/resolution. Writes should be atomic; session transcripts continue using JSONL and their existing lock.
- Add worker lifecycle events or equivalent durable session events for queued, started, progress, waiting, finished and stopped. The UI can derive live status from engine events and recover final status on relaunch.
- Add per-lead accounting aggregation and budget enforcement at the dispatch/provider boundary. Workers inherit limits; cap exhaustion blocks further paid work and creates one deduplicated spend attention item.
- Treat chief decisions as structured response actions that render tappable choices. Persist both the decision and the action receipt before notifying a lead or continuing a gated operation.
- Add a Pond sidebar mode: lead rows only, one-line `now:` status, expandable active-worker count/list, and completed worker history under the lead. Keep archive/search available for old sessions without surfacing workers as top-level rows.
- Add a chief-window controller with global hotkey, floating panel level, restore position, and pill/expanded states. It uses the ordinary conversation rendering and session machinery.
- Add per-lead PR/CI presentation and a merge action routed through attention, with a durable result receipt.
- Migrate existing parent relationships only when explicitly creating Pond roles; do not reinterpret the current generic session tree as lead/worker hierarchy.

## Wireframes

Chief window (expanded):

```text
╭────────────────────────────────────────────────────────────╮
│  frog · chief                              ─  □  ×         │
│  global brief · memory                                      │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  You: get the mac build unstuck and report back             │
│                                                            │
│  Chief: I’ll ask the macOS lead to inspect the signing      │
│         failure, then bring you the fix and verification.   │
│                                                            │
│  [Approve delegation]  [Edit task]  [Keep it here]         │
│                                                            │
├────────────────────────────────────────────────────────────┤
│  + Ask the chief…                                  ↑       │
╰────────────────────────────────────────────────────────────╯
```

Chief window (collapsed):

```text
╭────────────────────────────────────────╮
│  ●  frog · 2 need you        ↑     ⋯   │
╰────────────────────────────────────────╯
```

Sidebar:

```text
╭──────────────────────────────╮
│ POND                    + lead│
├──────────────────────────────┤
│ NEEDS YOU                    │  <- only orange surface
│  Review deploy plan · Infra   │
│  $8.20 cap request · Models   │
├──────────────────────────────┤
│ ● Infra                      │
│   now: tracing auth timeout  │
│   2 workers             ▾    │
│     ● reproduce timeout      │
│     ◌ add request tracing    │
│   PR #42 · CI 5/5 · Merge    │
│   $12.40 / $25 today         │
│                              │
│ ● macOS                      │
│   now: signing fix verified  │
│   0 workers                  │
│   PR #87 · CI running        │
│   $3.10 / $10 today          │
│                              │
│ ○ Release                    │
│   now: waiting for direction │
│   1 worker              ▸    │
╰──────────────────────────────╯
```

## Ordered implementation steps

1. Define the versioned Pond metadata schema, atomic store, role/parent validation, and migration-free behavior for ordinary sessions.
2. Add engine APIs and lifecycle events to create/resume leads and linked workers, publish `now` summaries, and list active versus completed workers.
3. Add lead brief and memory editing/storage, with explicit lead-owned summarization of linked worker outcomes.
4. Implement the Pond sidebar roster and lead detail view, including worker expansion, completed-worker log, and per-lead PR/CI summary.
5. Implement structured chief decisions, durable attention items, receipts, and attention-driven approval/merge flows.
6. Add lead budgets, inherited worker accounting, cap enforcement, and spend attention requests.
7. Add the persistent floating chief panel, global hotkey, pill state, and restoration of geometry/session state.
8. Add integration coverage for restart recovery, parent validation, attention resolution, budget caps, and compatibility with ordinary sessions.

## Future: the head as the chief's body

Cam's idea (2026-10-22): a physical cortex head can be the chief's presence. It speaks announcements ("vcad PR is green, merge?") and asks NEEDS YOU questions aloud, takes spoken answers as button choices, and shows lead status on its display. The chief session stays the source of truth; the head is another client of the Pond store and the attention API, like the floating window.
