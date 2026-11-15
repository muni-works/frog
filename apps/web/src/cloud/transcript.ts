// Folds envelopes into what the session view draws. Pure, so tests can drive it directly.
import type { Decision, Envelope, FileDiff, ToolOutcome } from "./protocol";

export type Entry =
  | { kind: "user"; turn: number; text: string }
  | { kind: "assistant"; id: string; text: string; done: boolean }
  | { kind: "tool"; id: string; name: string; arg: string; outcome?: ToolOutcome; output: string; diff?: FileDiff }
  | { kind: "permission"; id: string; item: string; name: string; arg: string; preview?: FileDiff; reason?: string; decision?: Decision };

export interface Transcript {
  title: string | null;
  entries: Entry[];
  running: boolean;
}

export const empty = (): Transcript => ({ title: null, entries: [], running: false });

export function apply(t: Transcript, env: Envelope): Transcript {
  const entries = t.entries;
  const find = <K extends Entry["kind"]>(kind: K, id: string) =>
    entries.find((e): e is Extract<Entry, { kind: K }> => e.kind === kind && "id" in e && e.id === id);

  switch (env.event) {
    case "turn_started":
      entries.push({ kind: "user", turn: env.turn, text: env.input });
      return { ...t, running: true };
    case "turn_ended":
      return { ...t, running: false };
    case "titled":
      return { ...t, title: env.title };
    case "item_started":
      if (env.kind.type === "message") entries.push({ kind: "assistant", id: env.id, text: "", done: false });
      else if (env.kind.type === "tool_call") entries.push({ kind: "tool", id: env.id, name: env.kind.name, arg: env.kind.arg, output: "" });
      return { ...t };
    case "item_delta": {
      const d = env.delta;
      if (d.type === "text") {
        const e = find("assistant", env.id);
        if (e) e.text += d.text;
      } else if (d.type === "output") {
        const e = find("tool", env.id);
        if (e) e.output += d.text;
      }
      return { ...t };
    }
    case "item_completed": {
      const it = env.item;
      if (it.type === "message") {
        const e = find("assistant", env.id);
        if (e) Object.assign(e, { text: it.text, done: true });
        else entries.push({ kind: "assistant", id: env.id, text: it.text, done: true });
      } else if (it.type === "tool_call") {
        const done = { outcome: it.outcome, output: it.display ?? it.output, diff: it.diff };
        const e = find("tool", env.id);
        if (e) Object.assign(e, done);
        else entries.push({ kind: "tool", id: env.id, name: it.name, arg: it.arg, ...done });
      }
      return { ...t };
    }
    case "permission_request":
      entries.push({ kind: "permission", id: env.id, item: env.item, name: env.name, arg: env.arg, preview: env.preview, reason: env.reason });
      return { ...t };
    case "permission_resolved": {
      // Requests are live-only, so on replay there may be nothing to resolve.
      const e = find("permission", env.id);
      if (e) e.decision = env.decision;
      return { ...t };
    }
    default:
      return t;
  }
}

/** Requests still waiting on Allow or Deny. */
export const pending = (t: Transcript) => t.entries.filter((e) => e.kind === "permission" && !e.decision);
