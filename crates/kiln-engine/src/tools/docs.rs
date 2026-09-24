//! Docs: how an API works, from the project's installed dependencies, at the exact version it
//! builds against, offline. Rust crates come from Cargo.lock and the cargo registry's sources,
//! JS/TS packages from node_modules (README and .d.ts), Python ones from the project's venv
//! (docstrings and the package description). Snippets are ranked like grep, no model calls.

use super::rank::{self, Chunk};
use super::{Ctx, Output};
use crate::provider::ToolSpec;
use anyhow::{Result, bail};
use serde_json::{Value, json};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

const BUDGET: usize = 7_000;
/// Per package: files and bytes read, so a huge dependency can't stall a lookup.
const MAX_FILES: usize = 400;
const MAX_BYTES: usize = 4 * 1024 * 1024;
/// Direct dependencies searched when no package is named.
const MAX_PACKAGES: usize = 40;

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: "Docs".into(),
        description: "Look up how a dependency's API works in the version this project actually has installed \
(Rust crates via Cargo.lock, JS/TS packages in node_modules, Python packages in the venv). Offline and exact, \
so prefer it to web search for library APIs. `package` alone gives its overview; add `query` (an item name or \
a few words) for matching doc comments and signatures with file:line to Read. `query` alone searches the \
project's direct dependencies."
            .into(),
        schema: json!({
            "type": "object",
            "properties": {
                "package": { "type": "string", "description": "Crate, npm package or Python distribution name" },
                "query": { "type": "string", "description": "What to look for, e.g. `Client::timeout` or `retry backoff`" }
            }
        }),
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Eco {
    Rust,
    Js,
    Python,
}

impl Eco {
    fn name(self) -> &'static str {
        match self {
            Eco::Rust => "Rust",
            Eco::Js => "npm",
            Eco::Python => "Python",
        }
    }
}

#[derive(Clone, Debug)]
struct Pkg {
    eco: Eco,
    name: String,
    version: String,
    /// Where its sources are.
    dir: PathBuf,
    /// For Python: the import package or module inside `dir`, and the dist-info.
    module: Option<PathBuf>,
    meta: Option<PathBuf>,
}

/// Where to look, so tests can point at fixtures.
pub struct Env {
    pub root: PathBuf,
    pub cargo_home: PathBuf,
    /// Python site-packages dirs; None means find them (the venv, else `python3`).
    pub site: Option<Vec<PathBuf>>,
}

impl Env {
    pub fn for_project(root: &Path) -> Self {
        let cargo_home = std::env::var_os("CARGO_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| dirs::home_dir().unwrap_or_default().join(".cargo"));
        Self {
            root: root.to_path_buf(),
            cargo_home,
            site: None,
        }
    }
}

/// `serde-json`, `serde_json` and `Serde.JSON` are the same package.
fn norm(s: &str) -> String {
    s.to_ascii_lowercase().replace(['-', '.'], "_")
}

fn up(root: &Path, name: &str) -> Option<PathBuf> {
    root.ancestors().map(|d| d.join(name)).find(|p| p.exists())
}

fn read(p: &Path) -> Option<String> {
    let bytes = std::fs::read(p).ok()?;
    if bytes.len() > MAX_BYTES || bytes[..bytes.len().min(8192)].contains(&0) {
        return None;
    }
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

// ---- Rust ----

struct Lock {
    /// (name, version, from a registry)
    packages: Vec<(String, String, bool)>,
    /// Dependencies of the workspace's own crates: name, and version when the lock says.
    direct: Vec<(String, Option<String>)>,
}

fn cargo_lock(root: &Path) -> Option<Lock> {
    let v: toml::Value = toml::from_str(&read(&up(root, "Cargo.lock")?)?).ok()?;
    let mut lock = Lock {
        packages: Vec::new(),
        direct: Vec::new(),
    };
    for p in v.get("package")?.as_array()? {
        let name = p.get("name").and_then(|v| v.as_str()).unwrap_or("");
        let version = p.get("version").and_then(|v| v.as_str()).unwrap_or("");
        let source = p.get("source").and_then(|v| v.as_str());
        lock.packages.push((
            name.into(),
            version.into(),
            source.is_some_and(|s| s.starts_with("registry+") || s.starts_with("sparse+")),
        ));
        if source.is_none() {
            for d in p
                .get("dependencies")
                .and_then(|d| d.as_array())
                .into_iter()
                .flatten()
            {
                let mut parts = d.as_str().unwrap_or("").split_whitespace();
                if let Some(n) = parts.next() {
                    lock.direct.push((n.into(), parts.next().map(String::from)));
                }
            }
        }
    }
    Some(lock)
}

fn registry_dir(env: &Env, name: &str, version: &str) -> Option<PathBuf> {
    let src = env.cargo_home.join("registry/src");
    std::fs::read_dir(src)
        .ok()?
        .flatten()
        .map(|e| e.path().join(format!("{name}-{version}")))
        .find(|p| p.is_dir())
}

fn rust_pkg(env: &Env, lock: &Lock, name: &str) -> Option<Pkg> {
    let n = norm(name);
    let pinned = lock
        .direct
        .iter()
        .find(|(d, v)| norm(d) == n && v.is_some())
        .and_then(|(_, v)| v.clone());
    // The version a workspace crate names, else the newest (the lock lists them in order).
    let (name, version, _) = lock
        .packages
        .iter()
        .rfind(|(p, v, reg)| *reg && norm(p) == n && pinned.as_ref().is_none_or(|x| x == v))?;
    Some(Pkg {
        eco: Eco::Rust,
        name: name.clone(),
        version: version.clone(),
        dir: registry_dir(env, name, version)?,
        module: None,
        meta: None,
    })
}

/// Doc comments with the item they document: `//!` blocks as module docs, `///` blocks with
/// the signature that follows.
fn rust_chunks(text: &str, rel: &str) -> Vec<Chunk> {
    let lines: Vec<&str> = text.lines().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let t = lines[i].trim_start();
        let inner = t.starts_with("//!");
        if !(inner || (t.starts_with("///") && !t.starts_with("////"))) {
            i += 1;
            continue;
        }
        let start = i;
        let marker = if inner { "//!" } else { "///" };
        let mut doc = String::new();
        while i < lines.len() && lines[i].trim_start().starts_with(marker) {
            let l = &lines[i].trim_start()[3..];
            doc.push_str(l.strip_prefix(' ').unwrap_or(l));
            doc.push('\n');
            i += 1;
        }
        let heading = if inner {
            format!("{rel} (module docs)")
        } else {
            // Skip attributes, then take the signature up to its body.
            while i < lines.len() && lines[i].trim_start().starts_with("#[") {
                i += 1;
            }
            let mut sig = String::new();
            for l in lines.iter().skip(i).take(4) {
                let l = l.trim();
                if l.starts_with("//") {
                    break;
                }
                sig.push_str(l);
                sig.push(' ');
                if l.contains('{') || l.ends_with(';') || l.ends_with(',') {
                    break;
                }
            }
            sig.split('{').next().unwrap_or("").trim().to_string()
        };
        out.push(Chunk {
            heading,
            body: doc.trim().to_string(),
            loc: format!("{rel}:{}", start + 1),
        });
    }
    out
}

// ---- JS / TS ----

fn node_modules(root: &Path) -> Option<PathBuf> {
    up(root, "node_modules").filter(|p| p.is_dir())
}

fn js_pkg(root: &Path, name: &str) -> Option<Pkg> {
    let nm = node_modules(root)?;
    let dir = nm.join(name);
    let pj: Value = serde_json::from_str(&read(&dir.join("package.json"))?).ok()?;
    Some(Pkg {
        eco: Eco::Js,
        name: name.into(),
        version: pj["version"].as_str().unwrap_or("?").into(),
        dir,
        module: None,
        meta: None,
    })
}

fn js_direct(root: &Path) -> Vec<String> {
    let Some(pj) = up(root, "package.json").and_then(|p| read(&p)) else {
        return Vec::new();
    };
    let v: Value = serde_json::from_str(&pj).unwrap_or_default();
    ["dependencies", "devDependencies", "peerDependencies"]
        .iter()
        .filter_map(|k| v[k].as_object())
        .flat_map(|o| o.keys().cloned())
        .collect()
}

/// JSDoc blocks with the declaration after them, and bare exported declarations.
fn dts_chunks(text: &str, rel: &str) -> Vec<Chunk> {
    let lines: Vec<&str> = text.lines().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let t = lines[i].trim();
        if t.starts_with("/**") {
            let start = i;
            let mut doc = String::new();
            loop {
                let l = lines[i]
                    .trim()
                    .trim_start_matches("/**")
                    .trim_end_matches("*/")
                    .trim_start_matches('*')
                    .trim();
                if !l.is_empty() {
                    doc.push_str(l);
                    doc.push('\n');
                }
                if lines[i].contains("*/") || i + 1 >= lines.len() {
                    break;
                }
                i += 1;
            }
            i += 1;
            let decl = lines.get(i).map(|l| l.trim()).unwrap_or("");
            out.push(Chunk {
                heading: decl.trim_end_matches('{').trim().to_string(),
                body: doc.trim().to_string(),
                loc: format!("{rel}:{}", start + 1),
            });
            i += 1;
            continue;
        }
        if t.starts_with("export ") || t.starts_with("declare ") {
            out.push(Chunk {
                heading: t.trim_end_matches('{').trim().to_string(),
                body: String::new(),
                loc: format!("{rel}:{}", i + 1),
            });
        }
        i += 1;
    }
    out
}

// ---- Python ----

fn site_dirs(env: &Env) -> Vec<PathBuf> {
    if let Some(s) = &env.site {
        return s.clone();
    }
    let mut dirs = Vec::new();
    for venv in [".venv", "venv", "env"] {
        let lib = env.root.join(venv).join("lib");
        for e in std::fs::read_dir(&lib).into_iter().flatten().flatten() {
            let sp = e.path().join("site-packages");
            if sp.is_dir() {
                dirs.push(sp);
            }
        }
    }
    if dirs.is_empty() {
        // The system Python's library dirs. Isolated, without `site`, so nothing from the
        // project (or a .pth file) runs.
        let out = std::process::Command::new("python3")
            .args([
                "-I",
                "-S",
                "-c",
                "import sysconfig,json;p=sysconfig.get_paths();print(json.dumps([p['purelib'],p['platlib']]))",
            ])
            .current_dir(std::env::temp_dir())
            .output();
        if let Ok(o) = out
            && let Ok(v) = serde_json::from_slice::<Vec<String>>(&o.stdout)
        {
            dirs.extend(v.into_iter().map(PathBuf::from));
            dirs.dedup();
        }
    }
    dirs
}

fn py_pkg(env: &Env, name: &str) -> Option<Pkg> {
    let n = norm(name);
    for site in site_dirs(env) {
        for e in std::fs::read_dir(&site).into_iter().flatten().flatten() {
            let file = e.file_name().to_string_lossy().into_owned();
            let Some(stem) = file.strip_suffix(".dist-info") else {
                continue;
            };
            let Some((dist, version)) = stem.split_once('-') else {
                continue;
            };
            if norm(dist) != n {
                continue;
            }
            let meta = e.path();
            let top = read(&meta.join("top_level.txt"))
                .and_then(|t| t.lines().next().map(|l| l.trim().to_string()))
                .filter(|t| !t.is_empty())
                .unwrap_or_else(|| n.clone());
            let module = [site.join(&top), site.join(format!("{top}.py"))]
                .into_iter()
                .find(|p| p.exists());
            return Some(Pkg {
                eco: Eco::Python,
                name: dist.into(),
                version: version.into(),
                dir: site.clone(),
                module,
                meta: Some(meta),
            });
        }
    }
    None
}

fn py_direct(root: &Path) -> Vec<String> {
    let name = |s: &str| {
        let n: String = s
            .trim()
            .chars()
            .take_while(|c| c.is_alphanumeric() || matches!(c, '-' | '_' | '.'))
            .collect();
        (!n.is_empty()).then_some(n)
    };
    let mut out = Vec::new();
    if let Some(t) = read(&root.join("pyproject.toml"))
        && let Ok(v) = toml::from_str::<toml::Value>(&t)
    {
        let deps = v.get("project").and_then(|p| p.get("dependencies"));
        for d in deps.and_then(|d| d.as_array()).into_iter().flatten() {
            out.extend(d.as_str().and_then(name));
        }
    }
    if let Some(t) = read(&root.join("requirements.txt")) {
        out.extend(
            t.lines()
                .filter(|l| !l.trim_start().starts_with(['#', '-']))
                .filter_map(name),
        );
    }
    out
}

/// Module docstrings, and `def`/`class` docstrings with their signatures.
fn py_chunks(text: &str, rel: &str) -> Vec<Chunk> {
    let lines: Vec<&str> = text.lines().collect();
    let mut out = Vec::new();
    let docstring = |mut i: usize| -> Option<(String, usize)> {
        let t = lines.get(i)?.trim();
        let t = t.trim_start_matches(['r', 'u', 'b']);
        let q = if t.starts_with("\"\"\"") {
            "\"\"\""
        } else if t.starts_with("'''") {
            "'''"
        } else {
            return None;
        };
        let first = &t[3..];
        if let Some(end) = first.find(q) {
            return Some((first[..end].trim().to_string(), i + 1));
        }
        let mut doc = format!("{}\n", first.trim());
        i += 1;
        while i < lines.len() {
            if let Some(end) = lines[i].find(q) {
                doc.push_str(lines[i][..end].trim());
                return Some((dedent(&doc), i + 1));
            }
            doc.push_str(lines[i]);
            doc.push('\n');
            i += 1;
        }
        None
    };
    // The module docstring: the first statement, after comments.
    if let Some(first) = lines
        .iter()
        .position(|l| !l.trim().is_empty() && !l.trim_start().starts_with('#'))
        && let Some((doc, _)) = docstring(first)
    {
        out.push(Chunk {
            heading: format!("{rel} (module docs)"),
            body: doc,
            loc: format!("{rel}:{}", first + 1),
        });
    }
    let mut i = 0;
    while i < lines.len() {
        let t = lines[i].trim_start();
        let def = t.starts_with("def ") || t.starts_with("async def ") || t.starts_with("class ");
        if !def || t.starts_with("def _") && !t.starts_with("def __init__") {
            i += 1;
            continue;
        }
        let start = i;
        let mut sig = String::new();
        while i < lines.len() {
            sig.push_str(lines[i].trim());
            sig.push(' ');
            if lines[i].trim_end().ends_with(':') {
                break;
            }
            i += 1;
        }
        i += 1;
        if let Some((doc, next)) = docstring(i) {
            out.push(Chunk {
                heading: sig.trim().trim_end_matches(':').to_string(),
                body: doc,
                loc: format!("{rel}:{}", start + 1),
            });
            i = next;
        }
    }
    out
}

fn dedent(s: &str) -> String {
    let indent = s
        .lines()
        .skip(1)
        .filter(|l| !l.trim().is_empty())
        .map(|l| l.len() - l.trim_start().len())
        .min()
        .unwrap_or(0);
    s.lines()
        .enumerate()
        .map(|(i, l)| {
            if i == 0 {
                l
            } else {
                l.get(indent..).unwrap_or(l.trim_start())
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

// ---- gathering ----

/// Turns one file's text into doc chunks.
type Parser = fn(&str, &str) -> Vec<Chunk>;

/// Files under `dir` with one of `exts`, skipping tests, examples and nested node_modules.
fn files(dir: &Path, exts: &[&str]) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = ignore::WalkBuilder::new(dir)
        .standard_filters(false)
        .filter_entry(|e| {
            let n = e.file_name().to_string_lossy();
            !matches!(
                n.as_ref(),
                "node_modules"
                    | "tests"
                    | "test"
                    | "__tests__"
                    | "benches"
                    | "examples"
                    | "target"
                    | ".git"
            )
        })
        .build()
        .flatten()
        .filter(|e| e.file_type().is_some_and(|t| t.is_file()))
        .map(|e| e.into_path())
        .filter(|p| {
            let s = p.to_string_lossy();
            exts.iter().any(|x| s.ends_with(x))
        })
        .collect();
    out.sort();
    out.truncate(MAX_FILES);
    out
}

fn readme(dir: &Path) -> Option<(String, String)> {
    [
        "README.md",
        "readme.md",
        "README.markdown",
        "README",
        "Readme.md",
    ]
    .iter()
    .find_map(|n| read(&dir.join(n)).map(|t| (n.to_string(), t)))
}

/// The package's README or long description (from Python's METADATA).
fn overview(p: &Pkg) -> Option<(String, String)> {
    match p.eco {
        Eco::Python => {
            let meta = read(&p.meta.as_ref()?.join("METADATA"))?;
            let body = meta.split_once("\n\n").map(|x| x.1).unwrap_or("").trim();
            (!body.is_empty()).then(|| ("METADATA".into(), body.to_string()))
        }
        _ => readme(&p.dir),
    }
}

/// Every doc chunk in a package, with paths relative to its directory.
fn chunks(p: &Pkg) -> Vec<Chunk> {
    let mut out = Vec::new();
    if let Some((name, text)) = overview(p) {
        for mut c in rank::markdown_chunks(&text, 1_500) {
            c.loc = name.clone();
            out.push(c);
        }
    }
    let (base, list, parse): (&Path, Vec<PathBuf>, Parser) = match p.eco {
        Eco::Rust => (&p.dir, files(&p.dir.join("src"), &[".rs"]), rust_chunks),
        Eco::Js => {
            let mut list = files(&p.dir, &[".d.ts", ".d.mts", ".d.cts"]);
            // Untyped packages often have types in @types/<name>.
            if list.is_empty() && !p.name.starts_with('@') {
                let types = p
                    .dir
                    .parent()
                    .unwrap_or(&p.dir)
                    .join("@types")
                    .join(&p.name);
                list = files(&types, &[".d.ts"]);
            }
            (p.dir.parent().unwrap_or(&p.dir), list, dts_chunks)
        }
        Eco::Python => match &p.module {
            Some(m) if m.is_dir() => (&p.dir, files(m, &[".py", ".pyi"]), py_chunks),
            Some(m) => (&p.dir, vec![m.clone()], py_chunks),
            None => (&p.dir, Vec::new(), py_chunks),
        },
    };
    let mut bytes = 0;
    for f in list {
        let Some(text) = read(&f) else { continue };
        bytes += text.len();
        if bytes > MAX_BYTES {
            break;
        }
        let rel = f.strip_prefix(base).unwrap_or(&f).display().to_string();
        out.extend(parse(&text, &rel));
    }
    out
}

fn find(env: &Env, lock: Option<&Lock>, name: &str) -> Vec<Pkg> {
    let mut out = Vec::new();
    if let Some(l) = lock {
        out.extend(rust_pkg(env, l, name));
    }
    out.extend(js_pkg(&env.root, name));
    if out.is_empty() {
        out.extend(py_pkg(env, name));
    }
    out
}

fn home(p: &Path) -> String {
    let s = p.display().to_string();
    match dirs::home_dir() {
        Some(h) if p.starts_with(&h) => format!("~{}", &s[h.display().to_string().len()..]),
        _ => s,
    }
}

fn header(p: &Pkg) -> String {
    let dir = p.module.as_ref().unwrap_or(&p.dir);
    format!("{} {} ({}, {})", p.name, p.version, p.eco.name(), home(dir))
}

fn write_chunk(out: &mut String, c: &Chunk) {
    let _ = writeln!(out, "\n{} — {}", c.loc, c.heading);
    for l in c.body.lines() {
        let _ = writeln!(out, "  {l}");
    }
}

/// Look it up. Returns (text for the model, short summary).
pub fn lookup(env: &Env, package: Option<&str>, query: Option<&str>) -> Result<(String, String)> {
    let query = query.map(str::trim).filter(|q| !q.is_empty());
    let package = package.map(str::trim).filter(|p| !p.is_empty());
    let lock = cargo_lock(&env.root);
    let pkgs: Vec<Pkg> = match package {
        Some(name) => {
            let found = find(env, lock.as_ref(), name);
            if found.is_empty() {
                bail!(
                    "`{name}` isn't installed for this project (looked in Cargo.lock and the cargo registry, node_modules, and Python site-packages). \
If it should be, fetch or install it first; otherwise try WebSearch/WebFetch."
                );
            }
            found
        }
        None => {
            let Some(q) = query else {
                bail!("pass `package`, `query`, or both");
            };
            let mut names: Vec<String> = lock
                .as_ref()
                .map(|l| l.direct.iter().map(|d| d.0.clone()).collect())
                .unwrap_or_default();
            names.extend(js_direct(&env.root));
            names.extend(py_direct(&env.root));
            names.sort();
            names.dedup();
            // A query that names a dependency searches just that one.
            let terms: Vec<String> = rank::terms(q).iter().map(|t| norm(t)).collect();
            let named: Vec<String> = names
                .iter()
                .filter(|n| terms.contains(&norm(n)))
                .cloned()
                .collect();
            let names = if named.is_empty() { names } else { named };
            let pkgs: Vec<Pkg> = names
                .iter()
                .take(MAX_PACKAGES)
                .flat_map(|n| find(env, lock.as_ref(), n))
                .collect();
            if pkgs.is_empty() {
                bail!(
                    "found no installed dependencies to search. Name a `package`, or try WebSearch."
                );
            }
            pkgs
        }
    };

    let mut out = String::new();
    let Some(q) = query else {
        // Overview: the crate/module docs and the README, then where to look next.
        let p = &pkgs[0];
        let _ = writeln!(out, "{}", header(p));
        let all = chunks(p);
        let mut used = 0;
        // The root module's docs (lib.rs, the package's __init__.py), then the README.
        let root_doc = |c: &&Chunk| {
            let file = c.loc.split(':').next().unwrap_or("");
            c.heading.ends_with("(module docs)")
                && (file == "src/lib.rs"
                    || (file.ends_with("__init__.py") && file.matches('/').count() == 1)
                    || (p.eco == Eco::Python && !file.contains('/')))
        };
        let lead = all
            .iter()
            .filter(root_doc)
            .chain(all.iter().filter(|c| !c.loc.contains(':')));
        for c in lead {
            if used + c.size() > BUDGET {
                break;
            }
            used += c.size();
            if c.loc.contains(':') {
                let _ = writeln!(out, "\n{}:\n{}", c.loc, c.body);
            } else {
                let _ = writeln!(out, "\n## {}\n{}", c.heading, c.body);
            }
        }
        let items = all.iter().filter(|c| c.loc.contains(':')).count();
        let _ = writeln!(
            out,
            "\n[{items} documented items. Pass `query` to search them.]"
        );
        return Ok((out, format!("{} {}", p.name, p.version)));
    };

    let mut all: Vec<(usize, Chunk)> = Vec::new();
    for (i, p) in pkgs.iter().enumerate() {
        all.extend(chunks(p).into_iter().map(|c| (i, c)));
    }
    let flat: Vec<Chunk> = all.iter().map(|(_, c)| c.clone()).collect();
    let hits = rank::top(&flat, q, BUDGET);
    if hits.is_empty() {
        let names: Vec<String> = pkgs
            .iter()
            .map(|p| format!("{} {}", p.name, p.version))
            .collect();
        return Ok((
            format!(
                "Nothing in {} matched \"{q}\". Try other words (an item name works best), or WebSearch.",
                names.join(", ")
            ),
            "no matches".into(),
        ));
    }
    let mut last = None;
    for &i in &hits {
        let (pi, c) = &all[i];
        if last != Some(*pi) {
            let _ = writeln!(
                out,
                "{}{}",
                if last.is_some() { "\n" } else { "" },
                header(&pkgs[*pi])
            );
            last = Some(*pi);
        }
        write_chunk(&mut out, c);
    }
    let n = hits.len();
    let summary = if pkgs.len() == 1 {
        format!(
            "{} {} · {n} match{}",
            pkgs[0].name,
            pkgs[0].version,
            if n == 1 { "" } else { "es" }
        )
    } else {
        format!(
            "{n} match{} in {} packages",
            if n == 1 { "" } else { "es" },
            pkgs.len()
        )
    };
    Ok((out, summary))
}

pub async fn run(input: &Value, ctx: &mut Ctx) -> Result<Output> {
    let env = Env::for_project(&ctx.cwd);
    let package = input["package"].as_str().map(String::from);
    let query = input["query"].as_str().map(String::from);
    let (content, summary) =
        tokio::task::spawn_blocking(move || lookup(&env, package.as_deref(), query.as_deref()))
            .await??;
    Ok(Output {
        content,
        display: Some(summary),
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(p: &Path, text: &str) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, text).unwrap();
    }

    /// A project with a Cargo.lock, a fake cargo registry, node_modules and a venv.
    fn fixture() -> Env {
        let base = std::env::temp_dir().join(format!("kiln-docs-{}", crate::session::new_id()));
        let root = base.join("proj");
        let cargo_home = base.join("cargo");
        write(
            &root.join("Cargo.lock"),
            r#"version = 4

[[package]]
name = "app"
version = "0.1.0"
dependencies = ["widget 2.1.0"]

[[package]]
name = "widget"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "widget"
version = "2.1.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
"#,
        );
        let reg = cargo_home.join("registry/src/index.crates.io-0000");
        write(&reg.join("widget-1.0.0/src/lib.rs"), "//! Old widget.\n");
        write(
            &reg.join("widget-2.1.0/README.md"),
            "# widget\n\nWidgets for everyone.\n\n## Retries\n\nWidgets retry with backoff.\n",
        );
        write(
            &reg.join("widget-2.1.0/src/lib.rs"),
            "//! Widgets, version two.\n\npub mod client;\n",
        );
        write(
            &reg.join("widget-2.1.0/src/client.rs"),
            "use std::time::Duration;\n\n/// A widget client.\npub struct Client;\n\nimpl Client {\n    /// Give up on a request after `d`.\n    ///\n    /// Defaults to 30 seconds.\n    #[inline]\n    pub fn timeout(self, d: Duration) -> Self {\n        self\n    }\n}\n",
        );
        write(
            &root.join("package.json"),
            r#"{"dependencies": {"left-pad": "^1.3.0"}}"#,
        );
        write(
            &root.join("node_modules/left-pad/package.json"),
            r#"{"name": "left-pad", "version": "1.3.0"}"#,
        );
        write(
            &root.join("node_modules/left-pad/index.d.ts"),
            "/**\n * Pad a string on the left.\n * @param len total length\n */\nexport default function leftPad(str: string, len: number, ch?: string): string;\n",
        );
        let site = root.join(".venv/lib/python3.12/site-packages");
        write(
            &site.join("requests_lite-0.5.0.dist-info/METADATA"),
            "Metadata-Version: 2.1\nName: requests-lite\n\n# requests-lite\n\nHTTP for humans, smaller.\n",
        );
        write(
            &site.join("requests_lite-0.5.0.dist-info/top_level.txt"),
            "requests_lite\n",
        );
        write(
            &site.join("requests_lite/__init__.py"),
            "\"\"\"HTTP, small.\"\"\"\n\ndef get(url, timeout=None):\n    \"\"\"Send a GET request.\n\n    :param timeout: seconds to wait\n    \"\"\"\n    pass\n",
        );
        Env {
            root,
            cargo_home,
            site: Some(vec![site]),
        }
    }

    #[test]
    fn rust_lookup_uses_the_locked_version() {
        let env = fixture();
        let (out, summary) = lookup(&env, Some("widget"), Some("timeout")).unwrap();
        assert!(summary.starts_with("widget 2.1.0"), "{summary}");
        assert!(
            out.contains("src/client.rs:7 — pub fn timeout(self, d: Duration) -> Self"),
            "{out}"
        );
        assert!(out.contains("Defaults to 30 seconds."));
        let (over, _) = lookup(&env, Some("widget"), None).unwrap();
        assert!(over.contains("Widgets, version two."), "{over}");
        assert!(over.contains("Widgets for everyone."));
        assert!(!over.contains("Old widget"));
    }

    #[test]
    fn js_and_python_lookups() {
        let env = fixture();
        let (out, summary) = lookup(&env, Some("left-pad"), Some("pad")).unwrap();
        assert_eq!(summary, "left-pad 1.3.0 · 1 match");
        assert!(
            out.contains("index.d.ts:1 — export default function leftPad"),
            "{out}"
        );
        let (out, summary) = lookup(&env, Some("requests-lite"), Some("get timeout")).unwrap();
        assert!(summary.starts_with("requests_lite 0.5.0"), "{summary}");
        assert!(out.contains("def get(url, timeout=None)"), "{out}");
        assert!(out.contains(":param timeout: seconds to wait"));
    }

    #[test]
    fn query_alone_searches_direct_dependencies() {
        let env = fixture();
        let (out, _) = lookup(&env, None, Some("retry backoff")).unwrap();
        assert!(out.contains("Widgets retry with backoff."), "{out}");
        assert!(lookup(&env, Some("nope"), None).is_err());
        assert!(lookup(&env, None, None).is_err());
    }
}
