//! `frog --muon`: launcher intent on a muon node (muon's docs/ecosystem.md, "launcher intent").
//!
//! frog is `agent:frog` twice over: an MCP client of `muon-agentd --mcp` (the capability
//! contract: it sees every capability and every call it makes is a `cap.invoke` that policy
//! decides) and a client of the event bus (`$XDG_RUNTIME_DIR/muon/bus.sock`), where it hears
//! `intent.submitted` / `plan.run` / `plan.cancel` from the launcher and answers with
//! `plan.proposed`, `plan.step`, `intent.answer` and `intent.result`, every one citing what
//! led to it in `causes`, so the flight recorder chains a result back to the sentence typed.
//!
//! One intent: plan (the model may first `look` with read capabilities to learn ids), then
//! wait for the person to run it (all, or a step at a time). A question that needs no
//! capability streams an answer instead. The model is the configured default (tang on mew),
//! then `mew-ollama` if that profile exists and the default fails.

use anyhow::{Context, Result, anyhow, bail};
use frog_engine::config::{Config, Profile};
use frog_engine::mcp::{self, Host, Hub, ServerConfig};
use frog_engine::message::{Block, Message, Role};
use frog_engine::provider::{Provider, Request, StreamEvent};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

const SERVER: &str = "muon";
const MODEL_TIMEOUT: Duration = Duration::from_secs(120);
/// Rounds of `look` before the model must plan or answer.
const LOOKS: usize = 2;
/// How often a streaming answer is republished.
const ANSWER_EVERY: Duration = Duration::from_millis(250);

fn bus_path() -> PathBuf {
    let rt = std::env::var("XDG_RUNTIME_DIR")
        .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }));
    PathBuf::from(rt).join("muon/bus.sock")
}

/// One request/response connection to the bus (publishing).
struct Bus {
    io: tokio::sync::Mutex<(BufReader<OwnedReadHalf>, OwnedWriteHalf)>,
}

impl Bus {
    async fn connect() -> Result<(Self, Value)> {
        let p = bus_path();
        let s = UnixStream::connect(&p)
            .await
            .with_context(|| format!("{} (is muon-agentd running?)", p.display()))?;
        let (r, w) = s.into_split();
        let bus = Bus {
            io: tokio::sync::Mutex::new((BufReader::new(r), w)),
        };
        let hello = bus
            .request(json!({"op": "hello", "actor": "agent:frog"}))
            .await?;
        if hello["ok"] != true {
            bail!("bus hello: {}", hello["error"]);
        }
        Ok((bus, hello))
    }

    async fn request(&self, req: Value) -> Result<Value> {
        let mut io = self.io.lock().await;
        let mut line = serde_json::to_vec(&req)?;
        line.push(b'\n');
        io.1.write_all(&line).await?;
        let mut s = String::new();
        if io.0.read_line(&mut s).await? == 0 {
            bail!("bus closed");
        }
        Ok(serde_json::from_str(&s)?)
    }

    /// Publish as agent:frog; returns the event's id ("" if refused).
    async fn publish(&self, kind: &str, data: Value, causes: &[&str]) -> String {
        let ev = json!({"kind": kind, "source": "frog", "data": data, "causes": causes});
        match self.request(json!({"op": "publish", "event": ev})).await {
            Ok(r) if r["ok"] == true => r["id"].as_str().unwrap_or("").to_string(),
            Ok(r) => {
                eprintln!("frog --muon: publish {kind}: {}", r["error"]);
                String::new()
            }
            Err(e) => {
                eprintln!("frog --muon: publish {kind}: {e:#}");
                String::new()
            }
        }
    }
}

#[derive(Clone)]
struct Step {
    cap: String,
    params: Value,
    label: String,
    effect: String,
}

struct Plan {
    intent_id: String,
    intent: String,
    steps: Vec<Step>,
    next: usize,
    running: bool,
    results: Vec<Value>,
}

struct Frog {
    bus: Bus,
    hub: Hub,
    node: String,
    models: Vec<(String, Profile)>,
    context: String,
    plans: Mutex<HashMap<String, Plan>>,
    /// intent ids (and plan ids) the person cancelled
    cancelled: Mutex<HashMap<String, Arc<AtomicBool>>>,
}

pub async fn run(cfg: Config, model: Option<String>) -> Result<bool> {
    let (bus, hello) = Bus::connect().await?;
    let node = hello["node"].as_str().unwrap_or("this node").to_string();

    let mut models = vec![cfg.resolve(model.as_deref())?];
    if models[0].0 != "mew-ollama"
        && let Ok(m) = cfg.resolve(Some("mew-ollama"))
        && cfg.models.contains_key("mew-ollama")
    {
        models.push(m);
    }

    // the capability contract: muon-agentd's MCP server, as agent:frog
    let agentd = std::env::var("MUON_AGENTD").unwrap_or_else(|_| "muon-agentd".into());
    let mut servers = BTreeMap::new();
    servers.insert(
        SERVER.to_string(),
        ServerConfig {
            command: Some(agentd),
            args: vec!["--mcp".into(), "--name".into(), "frog".into()],
            trust: true,
            enabled: true,
            ..Default::default()
        },
    );
    let root = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/"));
    let hub = Hub::connect(servers, Host::headless(&root)).await;
    if !hub.handles(&mcp::exposed_name(SERVER, "muon_call")) {
        let why: Vec<String> = hub.status().iter().map(|s| format!("{s:?}")).collect();
        bail!("muon-agentd --mcp didn't connect: {}", why.join("; "));
    }

    let mut context = String::new();
    for p in [
        PathBuf::from("/usr/share/muon/context.md"),
        dirs::config_dir()
            .unwrap_or_default()
            .join("muon/context.md"),
    ] {
        if let Ok(t) = std::fs::read_to_string(&p) {
            context.push_str(t.trim());
            context.push('\n');
        }
    }

    let frog = Arc::new(Frog {
        bus,
        hub,
        node,
        models,
        context,
        plans: Mutex::new(HashMap::new()),
        cancelled: Mutex::new(HashMap::new()),
    });
    eprintln!(
        "frog --muon: agent:frog on {} ({}), model {}",
        bus_path().display(),
        frog.node,
        frog.models
            .iter()
            .map(|m| m.0.as_str())
            .collect::<Vec<_>>()
            .join(" → ")
    );

    // the listening connection: subscribe takes it over
    let s = UnixStream::connect(bus_path()).await?;
    let (r, mut w) = s.into_split();
    let mut r = BufReader::new(r);
    for req in [
        json!({"op": "hello", "actor": "agent:frog"}),
        json!({"op": "subscribe", "kinds": ["intent.submitted", "plan.run", "plan.cancel"]}),
    ] {
        let mut line = serde_json::to_vec(&req)?;
        line.push(b'\n');
        w.write_all(&line).await?;
        let mut s = String::new();
        r.read_line(&mut s).await?;
        let v: Value = serde_json::from_str(&s)?;
        if v["ok"] != true {
            bail!("bus: {}", v["error"]);
        }
    }
    let mut line = String::new();
    loop {
        line.clear();
        if r.read_line(&mut line).await? == 0 {
            eprintln!("frog --muon: bus closed");
            return Ok(false);
        }
        let Ok(v) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let ev = v["event"].clone();
        // only a person starts, runs or stops anything
        if ev["actor"] != "you" {
            continue;
        }
        let f = frog.clone();
        match ev["kind"].as_str().unwrap_or("") {
            "intent.submitted" => {
                let to = ev["data"]["agent"].as_str().unwrap_or("frog");
                if to == "frog" || to == "agent:frog" {
                    tokio::spawn(async move { f.intent(ev).await });
                }
            }
            "plan.run" => {
                tokio::spawn(async move { f.run_plan(ev).await });
            }
            "plan.cancel" => f.cancel(&ev),
            _ => {}
        }
    }
}

fn strip_think(s: &str) -> String {
    let mut s = s.to_string();
    while let (Some(a), Some(b)) = (s.find("<think>"), s.find("</think>")) {
        if b < a {
            break;
        }
        s.replace_range(a..b + "</think>".len(), "");
    }
    s.trim().to_string()
}

/// The first balanced JSON object in a reply.
fn json_in(s: &str) -> Option<Value> {
    let s = strip_think(s);
    let start = s.find('{')?;
    let mut depth = 0i32;
    let mut in_str = false;
    let mut esc = false;
    for (i, c) in s[start..].char_indices() {
        if in_str {
            match c {
                _ if esc => esc = false,
                '\\' => esc = true,
                '"' => in_str = false,
                _ => {}
            }
            continue;
        }
        match c {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return serde_json::from_str(&s[start..start + i + 1]).ok();
                }
            }
            _ => {}
        }
    }
    None
}

fn clip(s: &str, n: usize) -> String {
    if s.len() <= n {
        return s.to_string();
    }
    let mut end = n;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &s[..end])
}

impl Frog {
    fn flag(&self, id: &str) -> Arc<AtomicBool> {
        self.cancelled
            .lock()
            .unwrap()
            .entry(id.to_string())
            .or_default()
            .clone()
    }

    fn cancel(&self, ev: &Value) {
        for k in ["intent_id", "plan_id"] {
            if let Some(id) = ev["data"][k].as_str() {
                self.flag(id).store(true, Ordering::SeqCst);
            }
        }
        for c in ev["causes"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
        {
            self.flag(c).store(true, Ordering::SeqCst);
        }
    }

    /// A model call: the configured default, then the fallback. `on` sees streamed text.
    async fn complete(
        &self,
        system: &str,
        msgs: &[Message],
        max: u32,
        on: &mut (dyn FnMut(&str) + Send),
    ) -> Result<(String, String)> {
        let mut last = anyhow!("no model configured");
        for (name, profile) in &self.models {
            let p = match Provider::new(profile) {
                Ok(p) => p,
                Err(e) => {
                    last = e;
                    continue;
                }
            };
            let req = Request {
                system,
                messages: msgs,
                tools: &[],
                max_tokens: Some(max),
                format: None,
                think: Some(false),
                think_budget: None,
                cache_key: None,
            };
            let mut cb = |e: StreamEvent| {
                if let StreamEvent::Text(t) = e {
                    on(&t)
                }
            };
            match tokio::time::timeout(MODEL_TIMEOUT, p.complete(&req, &mut cb)).await {
                Ok(Ok(r)) => return Ok((name.clone(), strip_think(&r.message.text()))),
                Ok(Err(e)) => {
                    eprintln!("frog --muon: model {name}: {e:#}");
                    last = e
                }
                Err(_) => {
                    eprintln!("frog --muon: model {name}: timed out");
                    last = anyhow!("{name} timed out")
                }
            }
        }
        Err(last)
    }

    /// `muon_call` through MCP, as agent:frog. Always returns agentd's JSON reply.
    async fn call(
        &self,
        cap: &str,
        params: &Value,
        causes: &[&str],
        intent_id: &str,
        intent: &str,
    ) -> Value {
        let input = json!({"cap": cap, "params": params, "causes": causes, "intent_id": intent_id, "intent": intent});
        let tool = mcp::exposed_name(SERVER, "muon_call");
        let text = match self.hub.call(&format!("muon-{cap}"), &tool, &input).await {
            Ok(o) => o.content,
            Err(e) => format!("{e:#}"),
        };
        serde_json::from_str(&text).unwrap_or_else(|_| json!({"ok": false, "error": text}))
    }

    async fn caps(&self) -> Vec<Value> {
        let tool = mcp::exposed_name(SERVER, "muon_caps");
        let Ok(o) = self.hub.call("muon-caps", &tool, &json!({})).await else {
            return vec![];
        };
        let v: Value = serde_json::from_str(&o.content).unwrap_or_default();
        v["caps"].as_array().cloned().unwrap_or_default()
    }

    fn system(&self, caps: &[Value]) -> String {
        let mut list = String::new();
        for c in caps {
            if c["effect"] == "actuate" {
                continue;
            }
            let params: Vec<String> = c["params"]
                .as_object()
                .into_iter()
                .flatten()
                .map(|(k, t)| format!("{k}: {}", t.as_str().unwrap_or("")))
                .collect();
            list.push_str(&format!(
                "- {} ({}) {{{}}}: {}\n",
                c["name"].as_str().unwrap_or(""),
                c["effect"].as_str().unwrap_or(""),
                params.join(", "),
                c["summary"].as_str().unwrap_or("")
            ));
        }
        format!(
            "You are frog, the assistant built into muon, running on the node `{node}`. A person typed a sentence into the launcher. Decide what it needs and reply with ONE JSON object, nothing else.\n\n\
             Capabilities on {node} (name (effect) {{params}}: what it does):\n{list}\n\
             Reply shapes:\n\
             - {{\"kind\":\"plan\",\"steps\":[{{\"cap\":\"disk.usage\",\"params\":{{}},\"label\":\"Check free disk space\"}}]}} when it is about this node's state or asks to do something here. Reading counts: a question about disks, windows, settings or updates is a plan of read steps; the person sees the plan, runs it, and gets the answer from the results.\n\
             - {{\"kind\":\"look\",\"look\":[{{\"cap\":\"window.list\",\"params\":{{}}}}]}} only to learn ids or names that a later plan step needs as params (e.g. which window is \"my terminal\"). Read capabilities only. At most {LOOKS} looks. Never look to answer a question: plan it.\n\
             - {{\"kind\":\"answer\"}} when it is general knowledge or about the context below, needing no capability.\n\
             Rules: use only capabilities listed above, with params exactly as typed there (omit optional ones you don't need; never invent ids, look first). Fewest steps that do it, in order. A label is a short plain phrase a person reads, starting with a verb. If nothing listed can do it, answer and say so.\n\
             {ctx}",
            node = self.node,
            ctx = if self.context.is_empty() {
                String::new()
            } else {
                format!("\nContext:\n{}\n", self.context)
            },
        )
    }

    async fn intent(self: Arc<Self>, ev: Value) {
        let intent_id = ev["id"].as_str().unwrap_or("").to_string();
        let text = ev["data"]["text"].as_str().unwrap_or("").trim().to_string();
        if intent_id.is_empty() || text.is_empty() {
            return;
        }
        let stop = self.flag(&intent_id);
        let t0 = Instant::now();
        let caps = self.caps().await;
        let system = self.system(&caps);
        let mut msgs = vec![Message::user(text.clone())];
        let mut looked = String::new();
        let mut decided = None;
        for round in 0..=LOOKS {
            if round == LOOKS {
                msgs.push(Message::user(
                    "No more looks: reply with a plan or an answer now.",
                ));
            }
            let reply = match self.complete(&system, &msgs, 1024, &mut |_| {}).await {
                Ok(r) => r,
                Err(e) => {
                    self.fail(
                        &intent_id,
                        &format!(
                            "frog couldn't reach a model: {}",
                            clip(&format!("{e:#}"), 120)
                        ),
                    )
                    .await;
                    return;
                }
            };
            if stop.load(Ordering::SeqCst) {
                return;
            }
            if std::env::var_os("FROG_MUON_DEBUG").is_some() {
                eprintln!("frog --muon: round {round}: {}", reply.1);
            }
            let Some(v) = json_in(&reply.1) else {
                // a model that just answered in prose: that's the answer
                decided = Some(("answer".to_string(), json!({}), reply.0));
                break;
            };
            let kind = v["kind"].as_str().unwrap_or("answer").to_string();
            if kind == "look" && round < LOOKS {
                let mut out = Vec::new();
                for l in v["look"].as_array().into_iter().flatten().take(4) {
                    let cap = l["cap"].as_str().unwrap_or("");
                    let is_read = caps
                        .iter()
                        .any(|c| c["name"] == cap && c["effect"] == "read");
                    let r = if is_read {
                        self.call(cap, &l["params"], &[&intent_id], &intent_id, &text)
                            .await
                    } else {
                        json!({"ok": false, "error": "look is for read capabilities only"})
                    };
                    out.push(json!({"cap": cap, "reply": r}));
                }
                let s = clip(&serde_json::to_string(&out).unwrap_or_default(), 6000);
                looked.push_str(&s);
                msgs.push(Message {
                    role: Role::Assistant,
                    content: vec![Block::Text { text: reply.1 }],
                });
                msgs.push(Message::user(format!(
                    "Look results: {s}\nNow reply with a plan or an answer."
                )));
                continue;
            }
            // an id the model never saw is a guess: make it look first
            if kind == "plan" && round < LOOKS {
                let guessed: Vec<String> = v["steps"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|s| s["params"]["id"].as_u64())
                    .filter(|id| !looked.contains(&format!("\"id\":{id}")))
                    .map(|id| id.to_string())
                    .collect();
                if !guessed.is_empty() {
                    msgs.push(Message {
                        role: Role::Assistant,
                        content: vec![Block::Text { text: reply.1 }],
                    });
                    msgs.push(Message::user(format!(
                        "You used id {} without having seen it. Reply with a look (e.g. window.list) to find the real id first.",
                        guessed.join(", ")
                    )));
                    continue;
                }
            }
            decided = Some((kind, v, reply.0));
            break;
        }
        let Some((kind, v, model)) = decided else {
            return;
        };
        if kind == "plan" {
            let mut steps = Vec::new();
            for s in v["steps"].as_array().into_iter().flatten().take(8) {
                let cap = s["cap"].as_str().unwrap_or("");
                let Some(c) = caps.iter().find(|c| c["name"] == cap) else {
                    continue;
                };
                if c["effect"] == "actuate" {
                    continue;
                }
                steps.push(Step {
                    cap: cap.to_string(),
                    params: if s["params"].is_object() {
                        s["params"].clone()
                    } else {
                        json!({})
                    },
                    label: s["label"]
                        .as_str()
                        .filter(|l| !l.is_empty())
                        .unwrap_or(cap)
                        .to_string(),
                    effect: c["effect"].as_str().unwrap_or("write").to_string(),
                });
            }
            if steps.is_empty() {
                self.fail(
                    &intent_id,
                    "frog couldn't plan that with this node's capabilities.",
                )
                .await;
                return;
            }
            let data = json!({
                "intent_id": intent_id, "intent": text, "model": model, "ms": t0.elapsed().as_millis() as u64,
                "steps": steps.iter().enumerate().map(|(i, s)| {
                    let c = caps.iter().find(|c| c["name"] == s.cap.as_str()).cloned().unwrap_or_default();
                    // what workstation policy does for an agent: read and ui run, the rest asks
                    let asks = c["confirm"] == true || !matches!(s.effect.as_str(), "read" | "ui");
                    json!({"n": i + 1, "cap": s.cap, "params": s.params, "effect": s.effect, "label": s.label,
                           "asks": asks, "reversible": c["reversible"]})
                }).collect::<Vec<_>>(),
            });
            let plan_id = self.bus.publish("plan.proposed", data, &[&intent_id]).await;
            if plan_id.is_empty() {
                return;
            }
            self.plans.lock().unwrap().insert(
                plan_id,
                Plan {
                    intent_id,
                    intent: text,
                    steps,
                    next: 0,
                    running: false,
                    results: vec![],
                },
            );
            return;
        }

        // an answer, streamed into the card
        let sys = format!(
            "You are frog, the assistant built into muon, on the node `{}`. Answer the person in at most three short sentences of plain text (no markdown, no preamble).{}",
            self.node,
            if self.context.is_empty() {
                String::new()
            } else {
                format!("\nContext:\n{}", self.context)
            }
        );
        let mut q = text.clone();
        if !looked.is_empty() {
            q.push_str(&format!("\n\n(What frog read on this node: {looked})"));
        }
        // stream into the card: the provider callback is sync, so text goes through a
        // channel to a task that republishes the answer so far at most every ANSWER_EVERY
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        let me = self.clone();
        let iid = intent_id.clone();
        let ticker = tokio::spawn(async move {
            let mut so_far = String::new();
            let mut at = Instant::now();
            while let Some(t) = rx.recv().await {
                so_far.push_str(&t);
                if at.elapsed() >= ANSWER_EVERY && !so_far.trim().is_empty() {
                    at = Instant::now();
                    me.bus
                        .publish(
                            "intent.answer",
                            json!({"intent_id": iid, "text": strip_think(&so_far)}),
                            &[&iid],
                        )
                        .await;
                }
            }
        });
        let res = self
            .complete(&sys, &[Message::user(q)], 400, &mut move |t: &str| {
                let _ = tx.send(t.to_string());
            })
            .await;
        let _ = ticker.await;
        if stop.load(Ordering::SeqCst) {
            return;
        }
        match res {
            Ok((model, answer)) => {
                let answer = if answer.is_empty() {
                    "frog had nothing to say.".to_string()
                } else {
                    answer
                };
                self.bus
                    .publish("intent.result", json!({"intent_id": intent_id, "text": answer, "ok": true, "kind": "answer", "model": model}), &[&intent_id])
                    .await;
            }
            Err(e) => {
                self.fail(
                    &intent_id,
                    &format!(
                        "frog couldn't reach a model: {}",
                        clip(&format!("{e:#}"), 120)
                    ),
                )
                .await
            }
        }
    }

    async fn fail(&self, intent_id: &str, text: &str) {
        self.bus
            .publish(
                "intent.result",
                json!({"intent_id": intent_id, "text": text, "ok": false}),
                &[intent_id],
            )
            .await;
    }

    async fn run_plan(self: Arc<Self>, ev: Value) {
        let run_id = ev["id"].as_str().unwrap_or("").to_string();
        let plan_id = ev["data"]["plan_id"]
            .as_str()
            .or_else(|| ev["causes"][0].as_str())
            .unwrap_or("")
            .to_string();
        let one = ev["data"]["mode"] == "step";
        let (intent_id, intent, todo, start) = {
            let mut plans = self.plans.lock().unwrap();
            let Some(p) = plans.get_mut(&plan_id) else {
                return;
            };
            if p.running || p.next >= p.steps.len() {
                return;
            }
            p.running = true;
            let end = if one { p.next + 1 } else { p.steps.len() };
            (
                p.intent_id.clone(),
                p.intent.clone(),
                p.steps[p.next..end].to_vec(),
                p.next,
            )
        };
        let stop = self.flag(&plan_id);
        let istop = self.flag(&intent_id);
        let mut last = run_id.clone();
        for (k, s) in todo.iter().enumerate() {
            let n = start + k + 1;
            if stop.load(Ordering::SeqCst) || istop.load(Ordering::SeqCst) {
                self.finish_plan(&plan_id, false);
                return;
            }
            let base = json!({"plan_id": plan_id, "intent_id": intent_id, "n": n, "cap": s.cap, "label": s.label, "effect": s.effect});
            let mut d = base.clone();
            d["state"] = json!("running");
            self.bus.publish("plan.step", d, &[&plan_id, &last]).await;
            let r = self
                .call(&s.cap, &s.params, &[&plan_id, &last], &intent_id, &intent)
                .await;
            let inv = r["invoke"].as_str().unwrap_or("").to_string();
            let rid = r["result_id"].as_str().unwrap_or("").to_string();
            let mut d = base.clone();
            let causes: Vec<&str> = [plan_id.as_str(), inv.as_str(), rid.as_str()]
                .into_iter()
                .filter(|c| !c.is_empty())
                .collect();
            if r["ok"] == true {
                d["state"] = json!("done");
                d["result"] = json!(clip(&r["result"].to_string(), 400));
                last = self.bus.publish("plan.step", d, &causes).await;
                if let Some(p) = self.plans.lock().unwrap().get_mut(&plan_id) {
                    p.results
                        .push(json!({"step": s.label, "cap": s.cap, "result": r["result"]}));
                    p.next = n;
                }
                continue;
            }
            let denied = r["decision"]["decision"]
                .as_str()
                .is_some_and(|x| x != "allow")
                || r["error"].as_str().is_some_and(|e| e.starts_with("denied"));
            let reason = r["decision"]["reason"]
                .as_str()
                .or(r["error"].as_str())
                .unwrap_or("failed")
                .to_string();
            d["state"] = json!(if denied { "denied" } else { "failed" });
            d["reason"] = json!(reason);
            let sid = self.bus.publish("plan.step", d, &causes).await;
            let text = if denied {
                format!(
                    "Stopped at step {n}: {} was not allowed ({}).",
                    s.label.to_lowercase(),
                    clip(&reason, 80)
                )
            } else {
                format!("Step {n} failed: {}.", clip(&reason, 100))
            };
            self.bus
                .publish("intent.result", json!({"intent_id": intent_id, "plan_id": plan_id, "text": text, "ok": false, "kind": "plan", "stopped_at": n}), &[&plan_id, &sid])
                .await;
            self.notify(&text);
            self.finish_plan(&plan_id, true);
            return;
        }
        let (done, results) = {
            let mut plans = self.plans.lock().unwrap();
            let Some(p) = plans.get_mut(&plan_id) else {
                return;
            };
            p.running = false;
            (p.next >= p.steps.len(), p.results.clone())
        };
        if !done {
            return; // stepping: the launcher sends the next plan.run
        }
        let sys = "You report the outcome of a finished plan to the person who asked for it. Write ONE short sentence (at most 20 words) stating the result itself: numbers with units, names. Plain text, no preamble, no quotes.";
        let msg = format!(
            "Request: {intent}\nNode: {}\nSteps and results: {}",
            self.node,
            clip(&serde_json::to_string(&results).unwrap_or_default(), 8000)
        );
        let text = match self
            .complete(sys, &[Message::user(msg)], 120, &mut |_| {})
            .await
        {
            Ok((_, t)) if !t.is_empty() => t
                .lines()
                .next()
                .unwrap_or("")
                .trim()
                .trim_matches('"')
                .to_string(),
            _ => format!(
                "Done: {} step{}.",
                results.len(),
                if results.len() == 1 { "" } else { "s" }
            ),
        };
        self.bus
            .publish("intent.result", json!({"intent_id": intent_id, "plan_id": plan_id, "text": text, "ok": true, "kind": "plan"}), &[&plan_id, &last])
            .await;
        self.notify(&text);
        self.finish_plan(&plan_id, true);
    }

    fn finish_plan(&self, plan_id: &str, drop: bool) {
        let mut plans = self.plans.lock().unwrap();
        if drop {
            plans.remove(plan_id);
        } else if let Some(p) = plans.get_mut(plan_id) {
            p.running = false;
        }
    }

    fn notify(&self, text: &str) {
        let _ = std::process::Command::new("notify-send")
            .args(["-a", "frog", "-i", "eco.frog.Frog", "frog", text])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
}
