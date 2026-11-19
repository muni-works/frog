//! What the agent knows and can do, as the apps' Customize pages show it. Skills,
//! connections, rules and memory, each with what it adds to every turn (in tokens, measured on
//! the text the prompt builders actually produce), how often it's been used, and whether it's
//! on; and the changes those pages make. The wire shape is in `docs/customize-api.md`.

use super::Toggles;
use super::lines;
use super::usage::{self, Kind, Use};
use crate::config::Config;
use crate::context::Estimator;
use crate::harness::Tier;
use crate::memory::{Scope, Store};
use anyhow::{Context, Result, bail};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// What the report is measured against: the session's model, or a large one for the CLI.
pub struct Ctx<'a> {
    pub cfg: &'a Config,
    /// The project folder (or a chat's working folder).
    pub cwd: &'a Path,
    /// A chat: no project, so no project skills' scope, rules or project notes.
    pub chat: bool,
    pub est: Estimator,
    /// Whether `est` has been calibrated against a provider's counts.
    pub calibrated: bool,
    pub tier: Tier,
    pub window: u64,
    /// A small window: no skills catalog and no MCP instructions in the prompt.
    pub small_window: bool,
    /// Live MCP connections, when there are any.
    pub hub: Option<&'a crate::mcp::Hub>,
    /// Servers still connecting.
    pub connecting: &'a [String],
    /// Whether servers were connected at all (the CLI's `--no-connect` doesn't).
    pub connected: bool,
    pub memory: Option<&'a Store>,
}

impl Ctx<'_> {
    fn tokens(&self, chars: usize) -> u64 {
        if chars == 0 {
            return 0;
        }
        self.est.tokens(chars)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct Report {
    pub project: Option<String>,
    pub estimate: EstimateInfo,
    pub tokens: u64,
    pub skills: Skills,
    pub connections: Connections,
    pub rules: Rules,
    pub memory: Memory,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct EstimateInfo {
    pub chars_per_token: f64,
    pub calibrated: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, JsonSchema)]
pub struct UseInfo {
    pub count: u32,
    pub days: Vec<u32>,
    pub last: Option<LastInfo>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, JsonSchema)]
pub struct LastInfo {
    pub at: String,
    pub session: Option<String>,
    pub title: Option<String>,
}

impl From<&Use> for UseInfo {
    fn from(u: &Use) -> Self {
        Self {
            count: u.count,
            days: u.days.clone(),
            last: u.last.as_ref().map(|l| LastInfo {
                at: l.at.clone(),
                session: l.session.clone(),
                title: l.title.clone(),
            }),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct Skills {
    pub tokens: u64,
    pub budget_tokens: u64,
    pub names_only: bool,
    pub items: Vec<SkillItem>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct SkillItem {
    pub id: String,
    pub name: String,
    pub description: String,
    pub scope: String,
    pub source: String,
    pub path: Option<String>,
    pub on: bool,
    pub tokens: u64,
    pub tokens_if_on: u64,
    pub full_tokens: u64,
    pub shadowed_by: Option<String>,
    #[serde(rename = "use")]
    pub use_: UseInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct Connections {
    pub tokens: u64,
    pub deferred: bool,
    pub items: Vec<ConnectionItem>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct ConnectionItem {
    pub name: String,
    pub scope: String,
    pub source: String,
    pub on: bool,
    pub state: String,
    pub error: Option<String>,
    pub waiting: Option<String>,
    pub tokens: u64,
    pub tokens_if_all_on: u64,
    pub instructions_tokens: u64,
    pub tools: Vec<ToolItem>,
    #[serde(rename = "use")]
    pub use_: UseInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct ToolItem {
    pub name: String,
    pub exposed: String,
    pub description: String,
    pub state: String,
    pub why: Option<String>,
    pub read_only: Option<bool>,
    pub tokens: u64,
    pub tokens_if_on: u64,
    #[serde(rename = "use")]
    pub use_: UseInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct Rules {
    pub tokens: u64,
    pub files: Vec<RulesFile>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct RulesFile {
    pub path: String,
    pub scope: String,
    pub source: String,
    pub kind: String,
    pub applies: String,
    pub paths: Vec<String>,
    pub tokens: u64,
    pub full_tokens: u64,
    pub lines: Vec<LineInfo>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct LineInfo {
    pub n: usize,
    pub text: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct Memory {
    /// What memory adds to every call: the one fixed line in `per_turn` mode, the whole
    /// index in `index` mode.
    pub tokens: u64,
    pub omitted: usize,
    pub notes: Vec<NoteItem>,
    /// `whole`: the store fits, so every note rides every call; `per_turn`: past that,
    /// standing guidance rides and the rest come back per turn when they fit the message;
    /// `index`: no vectors here, the whole index within the model's budget.
    pub mode: String,
    /// How notes are compared: `lexical-1` is word and trigram similarity, not meaning.
    /// `None` in `index` mode.
    pub similarity: Option<String>,
    /// The map's groups (empty in `index` mode).
    pub groups: Vec<GroupItem>,
    /// Pairs that likely duplicate or disagree, for the user to settle (never resolved alone).
    pub pairs: Vec<PairItem>,
}

/// A coarse group of notes on the map.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct GroupItem {
    /// Its index; a note's `group` names it.
    pub id: usize,
    /// Two words from its notes ("staging and database").
    pub label: String,
    pub scope: String,
    /// Its centre, 0 to 1 on both axes.
    pub x: f32,
    pub y: f32,
    pub count: usize,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct NoteRef {
    pub id: String,
    pub scope: String,
}

/// Two notes that likely say the same thing or disagree.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct PairItem {
    /// Stable key, sent back with `memory_resolve`.
    pub key: String,
    /// `duplicate` or `disagree`.
    pub kind: String,
    pub older: NoteRef,
    pub newer: NoteRef,
    /// Always `["keep_newer", "show_both"]`.
    pub resolutions: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct NoteItem {
    pub id: String,
    pub scope: String,
    pub created: String,
    pub session: Option<String>,
    pub title: Option<String>,
    pub text: String,
    pub path: String,
    pub cites: Vec<String>,
    pub missing: Vec<String>,
    pub tokens: u64,
    pub omitted: bool,
    /// `user` (asked for) or `frog` (noted on its own).
    pub source: String,
    /// It rides every call (the whole store, or standing guidance); otherwise it comes back
    /// only on turns it fits.
    pub in_prompt: bool,
    /// For Frog's own notes: `said`, `correction` or `read`.
    pub kind: Option<String>,
    /// For `read`: the file it came from.
    pub from: Option<String>,
    /// The last turn it was brought into (RFC 3339).
    pub last_used: Option<String>,
    /// Not used (or written) in 60 days: faded on the map.
    pub stale: bool,
    /// Used in the most recent turn that used any note: lit on the map.
    pub lit: bool,
    /// Its place on the map, 0 to 1 on both axes, and its group (`None` in `index` mode).
    pub x: Option<f32>,
    pub y: Option<f32>,
    pub group: Option<usize>,
}

fn scope_label(project: bool) -> String {
    if project { "project" } else { "everywhere" }.into()
}

/// The whole snapshot.
pub fn report(ctx: &Ctx) -> Report {
    report_with(ctx, &Toggles::current(), &usage::summary())
}

pub(crate) fn report_with(ctx: &Ctx, toggles: &Toggles, uses: &Uses) -> Report {
    let skills = skills(ctx, toggles, uses);
    let connections = connections(ctx, toggles, uses);
    let rules = rules(ctx);
    let memory = memory(ctx);
    Report {
        project: (!ctx.chat).then(|| ctx.cwd.display().to_string()),
        estimate: EstimateInfo {
            chars_per_token: ctx.est.chars_per_token,
            calibrated: ctx.calibrated,
        },
        tokens: skills.tokens + connections.tokens + rules.tokens + memory.tokens,
        skills,
        connections,
        rules,
        memory,
    }
}

type Uses = BTreeMap<(Kind, String), Use>;

fn use_of(uses: &Uses, kind: Kind, key: &str) -> Use {
    uses.get(&(kind, key.to_string()))
        .cloned()
        .unwrap_or_default()
}

fn skills(ctx: &Ctx, toggles: &Toggles, uses: &Uses) -> Skills {
    use crate::skills;
    let user = !ctx.cfg.hermetic;
    let found = skills::scan(ctx.cwd, user);
    let active = skills::discover_with(ctx.cwd, user, toggles);
    let budget = skills::CATALOG_BUDGET;
    let in_prompt = !ctx.small_window;
    let parts = skills::catalog_parts(&active, budget);
    let line_tokens = |parts: &skills::CatalogParts, name: &str| {
        let sep = if parts.names_only { 2 } else { 1 };
        parts
            .lines
            .iter()
            .find(|(n, _)| n == name)
            .map_or(0, |(_, l)| ctx.tokens(l.len() + sep))
    };
    let items = found
        .iter()
        .map(|s| {
            let id = s.id();
            let on = toggles.skill_on(&s.name);
            let winner = active.get(&s.name).map(|w| w.id());
            let shadowed_by = winner.filter(|w| *w != id);
            let tokens = if on && shadowed_by.is_none() && in_prompt {
                line_tokens(&parts, &s.name)
            } else {
                0
            };
            // Off: what it would add if switched on, measured in the catalog it would join.
            let tokens_if_on = if tokens > 0 || !in_prompt {
                tokens
            } else {
                let mut with = active.clone();
                with.insert(s.name.clone(), s.clone());
                line_tokens(&skills::catalog_parts(&with, budget), &s.name)
            };
            SkillItem {
                full_tokens: skills::load(s).map_or(0, |t| ctx.tokens(t.len())),
                name: s.name.clone(),
                description: s.description.clone(),
                scope: scope_label(s.project),
                source: s.source.into(),
                path: (s.source != "builtin").then(|| s.path.display().to_string()),
                on,
                tokens,
                tokens_if_on,
                shadowed_by,
                use_: (&use_of(uses, Kind::Skill, &id)).into(),
                id,
            }
        })
        .collect();
    Skills {
        tokens: if in_prompt {
            ctx.tokens(skills::catalog_within(&active, budget).len())
        } else {
            0
        },
        budget_tokens: ctx.tokens(budget),
        names_only: parts.names_only,
        items,
    }
}

fn connections(ctx: &Ctx, toggles: &Toggles, uses: &Uses) -> Connections {
    let (status, detail, loaded) = match ctx.hub {
        Some(h) => (h.status(), h.detail(), h.loaded()),
        None => Default::default(),
    };
    connections_from(ctx, toggles, uses, status, detail, &loaded)
}

/// [`connections`] from what the hub knows: each server's status and detail, and the tools
/// loaded on demand (sent every turn even when the rest are deferred).
pub(crate) fn connections_from(
    ctx: &Ctx,
    toggles: &Toggles,
    uses: &Uses,
    status: Vec<crate::mcp::ServerStatus>,
    detail: Vec<crate::mcp::ServerDetail>,
    loaded: &[String],
) -> Connections {
    let configured = crate::mcp::configured_from(ctx.cfg, ctx.cwd);
    let status: BTreeMap<String, crate::mcp::ServerStatus> =
        status.into_iter().map(|s| (s.name.clone(), s)).collect();
    let detail: BTreeMap<String, crate::mcp::ServerDetail> =
        detail.into_iter().map(|d| (d.name.clone(), d)).collect();

    // Tools the model would be offered, to know whether they're sent or loaded on demand.
    let offered: usize = detail
        .values()
        .filter(|d| {
            configured.get(&d.name).is_none_or(|(s, _)| s.enabled) && toggles.server_on(&d.name)
        })
        .flat_map(|d| d.tools.iter().map(move |t| (d, t)))
        .filter(|(d, t)| d.trust || crate::mcp::suspicious(t).is_none())
        .filter(|(d, t)| toggles.tool_on(&crate::mcp::exposed_name(&d.name, &t.name)))
        .count();
    let deferred = crate::mcp::defers(offered) || (offered > 0 && ctx.small_window);

    let mut items = Vec::new();
    for (name, (cfg, source)) in &configured {
        if cfg.command.is_none() && cfg.url.is_none() {
            continue;
        }
        let on = cfg.enabled && toggles.server_on(name);
        let st = status.get(name);
        let d = detail.get(name);
        let (state, waiting) = if !on {
            ("off", None)
        } else if d.is_some() {
            ("connected", None)
        } else if let Some(st) = st.filter(|s| s.needs_auth) {
            if crate::mcp::sign_in_refused(&st.auth_key) {
                ("declined", Some("sign_in"))
            } else {
                ("needs_sign_in", Some("sign_in"))
            }
        } else if st.is_some_and(|s| s.error.is_some()) {
            ("failed", None)
        } else if ctx.connecting.contains(name) {
            ("connecting", None)
        } else if ctx.connected {
            ("connecting", None)
        } else {
            ("unknown", None)
        };
        let mut tools = Vec::new();
        let mut instructions_tokens = 0;
        if let Some(d) = d {
            if !ctx.small_window
                && let Some(i) = &d.instructions
            {
                instructions_tokens = ctx.tokens(crate::mcp::instructions_block(name, i).len());
            }
            for t in &d.tools {
                let exposed = crate::mcp::exposed_name(name, &t.name);
                let why = (!d.trust).then(|| crate::mcp::suspicious(t)).flatten();
                let tool_on = toggles.tool_on(&exposed);
                let state = match (&why, tool_on) {
                    (Some(_), _) => "withheld",
                    (None, true) => "on",
                    (None, false) => "off",
                };
                let tokens_if_on = ctx.tokens(crate::mcp::spec_chars(name, t));
                let sent = !deferred || loaded.contains(&exposed);
                let tokens = if on && state == "on" && sent {
                    tokens_if_on
                } else {
                    0
                };
                tools.push(ToolItem {
                    name: t.name.to_string(),
                    description: t.description.as_deref().unwrap_or("").to_string(),
                    state: state.into(),
                    why,
                    read_only: t.annotations.as_ref().and_then(|a| a.read_only_hint),
                    tokens,
                    tokens_if_on,
                    use_: (&use_of(uses, Kind::Tool, &exposed)).into(),
                    exposed,
                });
            }
        }
        let instructions_tokens = if on { instructions_tokens } else { 0 };
        let tool_uses: Vec<Use> = tools
            .iter()
            .map(|t| use_of(uses, Kind::Tool, &t.exposed))
            .collect();
        items.push(ConnectionItem {
            name: name.clone(),
            scope: scope_label(*source == "project"),
            source: (*source).into(),
            on,
            state: state.into(),
            error: st
                .and_then(|s| s.error.clone())
                .filter(|_| state == "failed"),
            waiting: waiting.map(String::from),
            tokens: instructions_tokens + tools.iter().map(|t| t.tokens).sum::<u64>(),
            tokens_if_all_on: instructions_tokens
                + tools
                    .iter()
                    .filter(|t| t.state != "withheld")
                    .map(|t| t.tokens_if_on)
                    .sum::<u64>(),
            instructions_tokens,
            tools,
            use_: (&Use::sum(&tool_uses)).into(),
        });
    }
    let search = if deferred {
        ctx.tokens(crate::mcp::search_spec_chars())
    } else {
        0
    };
    Connections {
        tokens: search + items.iter().map(|c| c.tokens).sum::<u64>(),
        deferred,
        items,
    }
}

/// Whose file a rules or instruction file is, by where it lives.
fn rules_source(path: &Path) -> &'static str {
    let s = path.to_string_lossy();
    if s.contains("/.claude/") || path.file_name().is_some_and(|n| n == "CLAUDE.md") {
        "claude_code"
    } else if s.contains("/.agents/") || path.file_name().is_some_and(|n| n == "AGENTS.md") {
        "agents"
    } else {
        "frog"
    }
}

/// A file outside the project tree (home config, `~/.claude`, a folder above the project)
/// applies everywhere that folder does; we call the home ones "everywhere".
fn rules_scope(ctx: &Ctx, path: &Path) -> String {
    let home = dirs::home_dir().unwrap_or_default();
    let home_file = path.starts_with(crate::config::config_dir())
        || path.starts_with(home.join(".claude"))
        || path.parent() == Some(home.as_path());
    scope_label(!home_file && !ctx.chat)
}

fn rules(ctx: &Ctx) -> Rules {
    let mut files = Vec::new();
    for f in crate::prompt::instruction_files(ctx.cwd, ctx.cfg) {
        let Ok(text) = std::fs::read_to_string(&f) else {
            continue;
        };
        let tokens = ctx.tokens(crate::prompt::instruction_block(ctx.cwd, &f, &text).len());
        files.push(RulesFile {
            path: f.display().to_string(),
            scope: rules_scope(ctx, &f),
            source: rules_source(&f).into(),
            kind: "instructions".into(),
            applies: "always".into(),
            paths: Vec::new(),
            tokens,
            full_tokens: tokens,
            lines: line_infos(&text),
        });
    }
    if !ctx.chat {
        let rules = crate::rules::discover(ctx.cwd);
        let (parts, _) = crate::rules::prompt_parts(&rules, crate::rules::prompt_budget(ctx.tier));
        for r in &rules {
            let text = std::fs::read_to_string(&r.path).unwrap_or_default();
            let piece = parts
                .iter()
                .find(|(p, _)| *p == r.path)
                .map(|(_, s)| s.len());
            files.push(RulesFile {
                path: r.path.display().to_string(),
                scope: "project".into(),
                source: rules_source(&r.path).into(),
                kind: "rule".into(),
                applies: if r.scoped() { "paths" } else { "always" }.into(),
                paths: r.patterns.clone(),
                tokens: piece.map_or(0, |n| ctx.tokens(n)),
                full_tokens: ctx.tokens(r.body.len()),
                lines: line_infos(&text),
            });
        }
    }
    Rules {
        tokens: files.iter().map(|f| f.tokens).sum(),
        files,
    }
}

fn line_infos(text: &str) -> Vec<LineInfo> {
    lines::read(text)
        .into_iter()
        .map(|l| LineInfo {
            n: l.n,
            text: l.text,
        })
        .collect()
}

fn memory(ctx: &Ctx) -> Memory {
    let Some(store) = ctx.memory else {
        return Memory {
            tokens: 0,
            omitted: 0,
            notes: Vec::new(),
            mode: "index".into(),
            similarity: None,
            groups: Vec::new(),
            pairs: Vec::new(),
        };
    };
    let notes = store.load();
    let vectors = crate::memvec::Index::sync(store, &notes).ok();
    let (index, each, omitted) = crate::memory::index_parts(&notes, ctx.tier, ctx.window);
    let map = vectors
        .as_ref()
        .map(|v| crate::memmap::map(&notes, v));
    let last = |n: &crate::memory::Note| {
        vectors
            .as_ref()
            .and_then(|v| v.get(n.scope, &n.id))
            .and_then(|e| e.last_used.clone())
    };
    let latest = notes.iter().filter_map(last).max();
    // As the session places them (`engine::noting::place_notes`): whole while the store fits,
    // else standing guidance in the prompt and the rest per turn.
    let small = crate::memory::whole_budget(ctx.tier);
    let per_turn = vectors.is_some() && crate::memory::index_within(&notes, small).2 > 0;
    let standing: Vec<crate::memory::Note> = notes
        .iter()
        .filter(|n| crate::memory::standing(n))
        .cloned()
        .collect();
    let (standing_index, standing_each, _) = if per_turn {
        crate::memory::index_within(&standing, small)
    } else {
        (String::new(), Vec::new(), 0)
    };
    let now = chrono::Utc::now().timestamp();
    let items = notes
        .iter()
        .map(|n| {
            let line = each
                .iter()
                .find(|(id, scope, _)| *id == n.id && *scope == n.scope)
                .and_then(|(_, _, l)| l.as_ref());
            let placed = map
                .as_ref()
                .and_then(|m| m.notes.iter().find(|p| p.id == n.id && p.scope == n.scope));
            NoteItem {
                id: n.id.clone(),
                scope: scope_label(n.scope == Scope::Project),
                created: n.created.clone(),
                session: n.session.clone(),
                title: n.session_title.clone(),
                text: n.body.clone(),
                path: n.path.display().to_string(),
                cites: n.cites.clone(),
                missing: n.missing.clone(),
                tokens: line.map_or(0, |l| ctx.tokens(l.len() + 1)),
                omitted: line.is_none() && vectors.is_none(),
                in_prompt: if per_turn {
                    standing_each
                        .iter()
                        .any(|(id, sc, l)| *id == n.id && *sc == n.scope && l.is_some())
                } else {
                    line.is_some()
                },
                source: n.source.clone(),
                kind: n.kind.clone(),
                from: n.from.clone(),
                stale: crate::memmap::stale(n, last(n).as_deref(), now),
                lit: latest.is_some() && last(n) == latest,
                last_used: last(n),
                x: placed.map(|p| p.x),
                y: placed.map(|p| p.y),
                group: placed.map(|p| p.group),
            }
        })
        .collect();
    let groups = map
        .as_ref()
        .map(|m| {
            m.groups
                .iter()
                .enumerate()
                .map(|(i, g)| GroupItem {
                    id: i,
                    label: g.label.clone(),
                    scope: scope_label(g.scope == Scope::Project),
                    x: g.x,
                    y: g.y,
                    count: g.count,
                })
                .collect()
        })
        .unwrap_or_default();
    let pairs = vectors
        .as_ref()
        .map(|v| {
            let r = |(s, id): &(Scope, String)| NoteRef {
                id: id.clone(),
                scope: scope_label(*s == Scope::Project),
            };
            crate::memmap::pairs(&notes, v, &v.settled())
                .iter()
                .map(|p| PairItem {
                    key: p.key.clone(),
                    kind: p.kind.label().into(),
                    older: r(&p.older),
                    newer: r(&p.newer),
                    resolutions: vec!["keep_newer".into(), "show_both".into()],
                })
                .collect()
        })
        .unwrap_or_default();
    Memory {
        tokens: if per_turn {
            ctx.tokens(standing_index.len() + crate::memory::PER_TURN.len())
        } else {
            ctx.tokens(index.len())
        },
        omitted: if per_turn { 0 } else { omitted },
        notes: items,
        mode: if per_turn {
            "per_turn"
        } else if vectors.is_some() {
            "whole"
        } else {
            "index"
        }
        .into(),
        similarity: vectors.as_ref().map(|_| crate::memvec::MODEL.to_string()),
        groups,
        pairs,
    }
}

// ---- changes ----

/// One change a Customize page makes. See `docs/customize-api.md`.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "change", rename_all = "snake_case")]
pub enum Edit {
    Skill {
        name: String,
        on: bool,
    },
    Connection {
        name: String,
        on: bool,
    },
    Tool {
        exposed: String,
        on: bool,
    },
    RuleAdd {
        #[serde(default)]
        path: Option<String>,
        #[serde(default = "project")]
        scope: String,
        text: String,
    },
    RuleEdit {
        path: String,
        n: usize,
        old: String,
        text: String,
    },
    RuleRemove {
        path: String,
        n: usize,
        old: String,
    },
    MemoryEdit {
        id: String,
        scope: String,
        text: String,
    },
    MemoryRemove {
        id: String,
        scope: String,
    },
    /// Settle a flagged pair (`pairs[].key`): `keep: "newer"` removes the older note;
    /// `keep: "both"` keeps both and stops flagging them.
    MemoryResolve {
        pair: String,
        keep: String,
    },
}

fn project() -> String {
    "project".into()
}

impl Edit {
    /// Whether it changes what the prompt holds (and so needs a session to rebuild it).
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Skill { .. } => "skills",
            Self::Connection { .. } | Self::Tool { .. } => "connections",
            Self::RuleAdd { .. } | Self::RuleEdit { .. } | Self::RuleRemove { .. } => "rules",
            Self::MemoryEdit { .. } | Self::MemoryRemove { .. } | Self::MemoryResolve { .. } => {
                "memory"
            }
        }
    }
}

fn note_scope(s: &str) -> Result<Scope> {
    match s {
        "project" => Ok(Scope::Project),
        "everywhere" | "global" => Ok(Scope::Global),
        other => bail!("scope is project or everywhere, not `{other}`"),
    }
}

/// The rules and instruction files a change may touch: the ones the report lists.
fn listed_rules_files(cfg: &Config, cwd: &Path, chat: bool) -> Vec<PathBuf> {
    let mut out = crate::prompt::instruction_files(cwd, cfg);
    if !chat {
        out.extend(crate::rules::discover(cwd).into_iter().map(|r| r.path));
    }
    out
}

/// Where a new line goes when the page doesn't name a file: the project's own instruction file
/// (the same one the agent's `Customize` tool writes, [`super::project_file`]), or the home
/// `FROG.md` for everywhere.
pub fn default_rules_file(cwd: &Path, scope: &str) -> PathBuf {
    if scope != "project" {
        return crate::config::config_dir().join("FROG.md");
    }
    super::project_file(cwd)
}

/// Make a change. `memory` is the store notes live in (`None` for no memory); `toggles` is the
/// file switches are kept in ([`Toggles::path`] outside a session).
pub fn apply(
    cfg: &Config,
    cwd: &Path,
    chat: bool,
    memory: Option<&Store>,
    toggles: &Path,
    change: &Edit,
) -> Result<()> {
    match change {
        Edit::Skill { name, on } => {
            let known = crate::skills::scan(cwd, !cfg.hermetic)
                .iter()
                .any(|s| s.name == *name);
            if !known {
                bail!("no skill `{name}` here");
            }
            Toggles::update_in(toggles, |t| Toggles::set(&mut t.skills_off, name, *on))
        }
        Edit::Connection { name, on } => {
            if !crate::mcp::configured_from(cfg, cwd).contains_key(name) {
                bail!("no connection `{name}` here");
            }
            Toggles::update_in(toggles, |t| Toggles::set(&mut t.servers_off, name, *on))
        }
        Edit::Tool { exposed, on } => {
            if !exposed.starts_with("mcp__") {
                bail!("`{exposed}` isn't a connection's tool");
            }
            Toggles::update_in(toggles, |t| Toggles::set(&mut t.tools_off, exposed, *on))
        }
        Edit::RuleAdd { path, scope, text } => {
            let file = match path {
                Some(p) => listed(cfg, cwd, chat, p)?,
                None => default_rules_file(cwd, scope),
            };
            lines::add(&file, text)
        }
        Edit::RuleEdit { path, n, old, text } => {
            lines::edit(&listed(cfg, cwd, chat, path)?, *n, old, text)
        }
        Edit::RuleRemove { path, n, old } => lines::remove(&listed(cfg, cwd, chat, path)?, *n, old),
        Edit::MemoryEdit { id, scope, text } => {
            let store = memory.context("this session keeps no memory")?;
            store.edit(note_scope(scope)?, id, text).map(|_| ())
        }
        Edit::MemoryRemove { id, scope } => {
            let store = memory.context("this session keeps no memory")?;
            store.remove(note_scope(scope)?, id).map(|_| ())
        }
        Edit::MemoryResolve { pair, keep } => {
            let store = memory.context("this session keeps no memory")?;
            let notes = store.load();
            let mut index = crate::memvec::Index::sync(store, &notes)?;
            let found = crate::memmap::pairs(&notes, &index, &[])
                .into_iter()
                .find(|p| &p.key == pair)
                .context("those two notes aren't flagged (one was changed or removed)")?;
            match keep.as_str() {
                "newer" => store.remove(found.older.0, &found.older.1).map(|_| ()),
                "both" => index.settle(pair),
                other => bail!("keep is newer or both, not `{other}`"),
            }
        }
    }
}

fn listed(cfg: &Config, cwd: &Path, chat: bool, path: &str) -> Result<PathBuf> {
    let p = PathBuf::from(path);
    if listed_rules_files(cfg, cwd, chat).contains(&p) {
        Ok(p)
    } else {
        bail!("`{path}` isn't one of this project's rules files")
    }
}

#[cfg(test)]
#[path = "report_tests.rs"]
mod tests;
