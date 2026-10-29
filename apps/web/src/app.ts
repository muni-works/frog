// The web app: sidebar of cloud sessions, a transcript column and a composer.
import { Connection, Gateway, GatewayError, type ConnectionState } from "./client";
import type { Decision, FileDiff, SessionSummary } from "./protocol";
import { apply, empty, type Entry, type Transcript } from "./transcript";

const $ = <T extends HTMLElement>(sel: string) => document.querySelector(sel) as T;

const store = {
  get: (k: string) => {
    try {
      return localStorage.getItem(k);
    } catch {
      return null;
    }
  },
  set: (k: string, v: string) => {
    try {
      localStorage.setItem(k, v);
    } catch {}
  },
};

const params = new URLSearchParams(location.search);
const local = /^(localhost|127\.0\.0\.1|\[::1\])$/.test(location.hostname);
const origin = params.get("gateway") ?? store.get("frog.gateway") ?? (local ? location.origin : "https://cloud.frog.toys");

let gw: Gateway | null = null;
let conn: Connection | null = null;
let current: string | null = null;
let transcript: Transcript = empty();
let sessions: SessionSummary[] = [];

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls?: string, text?: string): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

// ---- sign-in (stub until frog.toys sign-in lands) ----

function signIn() {
  const token = store.get("frog.token");
  $("#signin").hidden = !!token;
  $("#shell").hidden = !token;
  if (!token) return;
  gw = new Gateway({ origin, token });
  void refresh();
}

$("#signin-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const v = ($("#token") as HTMLInputElement).value.trim();
  if (!v) return;
  store.set("frog.token", v);
  signIn();
});

// ---- sidebar ----

async function refresh() {
  if (!gw) return;
  try {
    sessions = (await gw.list()).sort((a, b) => b.updated - a.updated);
  } catch (err) {
    banner(err instanceof GatewayError && err.status === 401 ? "Sign in again." : `Can't reach Frog Cloud: ${(err as Error).message}`);
    return;
  }
  drawSidebar();
}

function drawSidebar() {
  const list = $("#sessions");
  list.replaceChildren(
    ...sessions.map((s) => {
      const b = el("button", "row" + (s.id === current ? " selected" : ""));
      b.append(el("span", "row-title", s.title || s.repo), el("span", "row-sub", s.branch));
      b.onclick = () => open(s.id);
      return b;
    }),
  );
  if (!sessions.length) list.append(el("p", "empty", "No cloud sessions yet."));
}

$("#connect-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("#repo") as HTMLInputElement;
  const repo = input.value.trim();
  if (!gw || !repo) return;
  try {
    const s = await gw.create({ repo });
    input.value = "";
    await refresh();
    open(s.id);
  } catch (err) {
    banner((err as Error).message);
  }
});

// ---- session view ----

function open(id: string) {
  if (!gw) return;
  conn?.close();
  current = id;
  transcript = empty();
  drawSidebar();
  draw();
  conn = gw.connect(id, {
    onEnvelope: (env) => {
      transcript = apply(transcript, env);
      draw();
    },
    onState: status,
  });
}

function status(s: ConnectionState) {
  if (s.state === "refused") {
    const b = banner("Update Frog to continue. ");
    const a = el("a", "", "Download");
    a.href = s.refused.upgrade;
    b.append(a);
  } else if (s.state === "connecting" && s.attempt > 0) banner("Reconnecting…");
  else if (s.state === "live") banner(null);
  else if (s.state === "closed" && s.code === 4004) banner("This session was deleted.");
}

function banner(text: string | null): HTMLElement {
  const b = $("#banner");
  b.hidden = text === null;
  b.textContent = text ?? "";
  return b;
}

function decide(id: string, decision: Decision) {
  conn?.send({ op: "permission", id, decision });
}

function diffCard(d: FileDiff, actions?: HTMLElement): HTMLElement {
  const card = el("div", "diff");
  const head = el("div", "diff-head");
  head.append(el("span", "diff-path", d.path), el("span", "diff-add", `+${d.added}`), el("span", "diff-del", `−${d.removed}`));
  card.append(head);
  const body = el("pre", "diff-body");
  for (const h of d.hunks)
    for (const l of h.lines) body.append(el("div", `line ${l.kind}`, (l.kind === "add" ? "+ " : l.kind === "remove" ? "- " : "  ") + l.text));
  card.append(body);
  if (actions) card.append(actions);
  return card;
}

function entry(e: Entry): HTMLElement {
  switch (e.kind) {
    case "user":
      return el("div", "msg user", e.text);
    case "assistant":
      return el("div", "msg assistant", e.text);
    case "tool": {
      const wrap = el("div", "tool" + (e.outcome && e.outcome !== "ok" ? ` ${e.outcome}` : ""));
      const line = el("div", "tool-line");
      line.append(el("span", "tool-name", e.name), el("span", "tool-arg", e.arg));
      wrap.append(line);
      if (e.diff) wrap.append(diffCard(e.diff));
      return wrap;
    }
    case "permission": {
      const actions = el("div", "actions");
      if (e.decision) actions.append(el("span", "resolved", e.decision === "deny" ? "Denied" : "Allowed"));
      else {
        const deny = el("button", "btn", "Deny");
        const allow = el("button", "btn primary", "Allow");
        deny.onclick = () => decide(e.id, "deny");
        allow.onclick = () => decide(e.id, "allow");
        actions.append(deny, allow);
      }
      if (e.preview) return diffCard(e.preview, actions);
      const card = el("div", "ask");
      card.append(el("div", "ask-text", `${e.name} wants to run ${e.arg}`));
      if (e.reason) card.append(el("div", "ask-reason", e.reason));
      card.append(actions);
      return card;
    }
  }
}

function draw() {
  $("#title").textContent = current ? (transcript.title ?? sessions.find((s) => s.id === current)?.title ?? "") : "";
  $("#composer").hidden = !current;
  $("#placeholder").hidden = !!current;
  const log = $("#transcript");
  const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 40;
  log.replaceChildren(...transcript.entries.map(entry));
  if (atBottom) log.scrollTop = log.scrollHeight;
}

// ---- composer ----

const text = $("#text") as HTMLTextAreaElement;
function submit() {
  const v = text.value.trim();
  if (!v || !conn) return;
  conn.send({ op: "submit", text: v });
  text.value = "";
}
$("#composer").addEventListener("submit", (e) => {
  e.preventDefault();
  submit();
});
text.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
    e.preventDefault();
    submit();
  }
});

signIn();
