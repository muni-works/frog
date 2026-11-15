// A recorded session, played back: shared by the fake engine (stream A stand-in) and the mock
// gateway (contract §8). Fixtures are JSON lines of envelopes (frog's `{"type":"event","env":…}`
// session-log lines work too). Durable ones are stored; deltas are live only.
import { readFileSync } from "node:fs";

// item_gisted is a frog engine event the vendored copy predates; without it a replayed
// attach drops every gist.
const DURABLE = new Set(["turn_started", "turn_ended", "item_started", "item_completed", "items_discarded", "permission_resolved", "question_resolved", "auto_approved", "permission_decision", "compacted", "compaction_failed", "context_pruned", "model_changed", "folder_changed", "shell_cwd", "mode_changed", "titled", "chapter_titled", "pane_opened", "pane_closed", "pane_checkpoint", "background_started", "background_done", "item_gisted", "wakes_delivered", "message_read"]);

export const isDurable = (e) => DURABLE.has(e.event) || (e.event === "item_delta" && e.delta?.type === "image_preview");

/** Envelope bodies (seq, session, created stripped) from a fixture file. */
export function loadFixture(path) {
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((l) => l.trim())
    .map((l) => JSON.parse(l))
    .map((v) => (v.type === "event" ? v.env : v))
    .filter((e) => typeof e.event === "string")
    .map(({ seq, session, created, ...rest }) => rest);
}

/** One session's log and its attached peers. `emit` stamps seq/session/created and fans out. */
export class Recorded {
  constructor(id, events) {
    this.id = id;
    this.events = events;
    this.seq = 0;
    this.log = []; // durable envelopes, as text
    this.peers = new Set();
    this.resolved = new Set();
    this.turn = 0;
  }

  emit(body) {
    const env = { seq: ++this.seq, session: this.id, created: Date.now(), ...body };
    const text = JSON.stringify(env);
    if (isDurable(env)) this.log.push({ seq: env.seq, text });
    for (const p of this.peers) p.send(text);
    return env;
  }

  after(seq) {
    return this.log.filter((e) => e.seq > seq).map((e) => e.text);
  }

  lastSeq() {
    return this.log.length ? this.log[this.log.length - 1].seq : 0;
  }

  /** Play the recorded turn, pausing at each permission_request until someone answers it. */
  async play(input, delayMs = 15) {
    this.turn += 1;
    const turn = this.turn;
    for (const e of this.events) {
      if (e.event === "turn_started") {
        this.emit({ ...e, turn, input });
        continue;
      }
      if (e.event === "permission_request") {
        const id = `${e.id}-t${turn}`;
        this.emit({ ...e, id });
        await new Promise((resolve) => (this.waiting = { id, resolve }));
        continue;
      }
      this.emit("turn" in e ? { ...e, turn } : e);
      if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
    }
  }

  /** Op::Permission: the first answer for an id wins; later ones are dropped silently. */
  permission(op) {
    if (this.resolved.has(op.id)) return;
    this.resolved.add(op.id);
    this.emit({ event: "permission_resolved", id: op.id, decision: op.decision });
    if (this.waiting?.id === op.id) {
      const { resolve } = this.waiting;
      this.waiting = null;
      resolve();
    }
  }
}
