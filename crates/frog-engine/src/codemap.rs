//! Code maps: the project's structure as a diagram, computed from the code (no model).
//!
//! Files are linked by what they reference (Rust modules and crate paths, TS/JS and Python
//! imports, Go packages, Swift type references), then collapsed to directories until the map
//! is readable. Nodes carry recent git churn as `heat`, so hot spots stand out.

use crate::diagram::{Diagram, Direction, Edge, EdgeStyle, Group, Kind, Node};
use regex::Regex;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

const EXTS: &[&str] = &["rs", "ts", "tsx", "js", "jsx", "mjs", "py", "go", "swift"];
const MAX_FILE_BYTES: u64 = 512 * 1024;

pub struct Options {
    /// Map only this subdirectory (relative to the root).
    pub focus: Option<PathBuf>,
    /// Most nodes before collapsing files into directories.
    pub max_nodes: usize,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            focus: None,
            max_nodes: 30,
        }
    }
}

/// A file-level dependency graph, paths relative to the root.
#[derive(Default, Debug)]
pub struct Graph {
    pub files: Vec<String>,
    /// (from, to) -> number of references.
    pub edges: BTreeMap<(String, String), usize>,
}

/// Build the map for `root`.
pub fn map(root: &Path, opts: &Options) -> Diagram {
    map_with_summary(root, opts).0
}

/// The map, plus a text form listing every dependency (the drawn map omits edges implied by
/// others).
pub fn map_with_summary(root: &Path, opts: &Options) -> (Diagram, String) {
    let graph = scan(root, opts.focus.as_deref());
    let churn = churn(root);
    let mut d = to_diagram(root, &graph, &churn, opts);
    let text = summary(&d);
    reduce(&mut d);
    (d, text)
}

/// Transitive reduction between cycles: drop a -> c when c's strongly connected component is
/// reachable from a's through some other component. Edges inside a cycle all stay (in a cycle
/// everything reaches everything, so a plain reduction would erase it). Dependency graphs are
/// dense; this keeps the drawing to the edges that carry information.
fn reduce(d: &mut Diagram) {
    let ids: Vec<String> = d.nodes.iter().map(|n| n.id.clone()).collect();
    let index: HashMap<&str, usize> = ids
        .iter()
        .enumerate()
        .map(|(i, s)| (s.as_str(), i))
        .collect();
    let n = ids.len();
    let mut adj: Vec<Vec<usize>> = vec![Vec::new(); n];
    for e in &d.edges {
        if let (Some(&a), Some(&b)) = (index.get(e.from.as_str()), index.get(e.to.as_str())) {
            adj[a].push(b);
        }
    }
    let comp = scc(&adj);
    let comps = comp.iter().copied().max().map_or(0, |m| m + 1);
    let mut cadj: Vec<HashSet<usize>> = vec![HashSet::new(); comps];
    for a in 0..n {
        for &b in &adj[a] {
            if comp[a] != comp[b] {
                cadj[comp[a]].insert(comp[b]);
            }
        }
    }
    // Is component `to` reachable from `from` other than by the direct step?
    let indirect = |from: usize, to: usize| -> bool {
        let mut seen = vec![false; comps];
        let mut stack: Vec<usize> = cadj[from].iter().copied().filter(|&c| c != to).collect();
        while let Some(c) = stack.pop() {
            if c == to {
                return true;
            }
            if std::mem::replace(&mut seen[c], true) {
                continue;
            }
            stack.extend(cadj[c].iter().copied());
        }
        false
    };
    let before = d.edges.len();
    d.edges.retain(
        |e| match (index.get(e.from.as_str()), index.get(e.to.as_str())) {
            (Some(&a), Some(&b)) => comp[a] == comp[b] || !indirect(comp[a], comp[b]),
            _ => true,
        },
    );
    if d.edges.len() < before {
        d.title.push_str(&format!(
            " ({} of {} dependencies drawn)",
            d.edges.len(),
            before
        ));
    }
}

/// Strongly connected components (Tarjan), as a component index per node.
fn scc(adj: &[Vec<usize>]) -> Vec<usize> {
    struct T<'a> {
        adj: &'a [Vec<usize>],
        index: Vec<Option<usize>>,
        low: Vec<usize>,
        on: Vec<bool>,
        stack: Vec<usize>,
        comp: Vec<usize>,
        next: usize,
        comps: usize,
    }
    fn visit(t: &mut T, v: usize) {
        t.index[v] = Some(t.next);
        t.low[v] = t.next;
        t.next += 1;
        t.stack.push(v);
        t.on[v] = true;
        for i in 0..t.adj[v].len() {
            let w = t.adj[v][i];
            match t.index[w] {
                None => {
                    visit(t, w);
                    t.low[v] = t.low[v].min(t.low[w]);
                }
                Some(iw) if t.on[w] => t.low[v] = t.low[v].min(iw),
                _ => {}
            }
        }
        if Some(t.low[v]) == t.index[v] {
            while let Some(w) = t.stack.pop() {
                t.on[w] = false;
                t.comp[w] = t.comps;
                if w == v {
                    break;
                }
            }
            t.comps += 1;
        }
    }
    let n = adj.len();
    let mut t = T {
        adj,
        index: vec![None; n],
        low: vec![0; n],
        on: vec![false; n],
        stack: Vec::new(),
        comp: vec![0; n],
        next: 0,
        comps: 0,
    };
    for v in 0..n {
        if t.index[v].is_none() {
            visit(&mut t, v);
        }
    }
    t.comp
}

// MARK: - Scanning

pub(crate) fn source_files(root: &Path, focus: Option<&Path>) -> Vec<String> {
    let start = focus
        .map(|f| root.join(f))
        .unwrap_or_else(|| root.to_path_buf());
    let mut out: Vec<String> = ignore::WalkBuilder::new(&start)
        .hidden(true)
        .build()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_some_and(|t| t.is_file()))
        .filter(|e| {
            e.path()
                .extension()
                .and_then(|x| x.to_str())
                .is_some_and(|x| EXTS.contains(&x))
        })
        .filter(|e| e.metadata().is_ok_and(|m| m.len() <= MAX_FILE_BYTES))
        .filter_map(|e| {
            e.path()
                .strip_prefix(root)
                .ok()
                .map(|p| p.to_string_lossy().into_owned())
        })
        .filter(|p| {
            !p.split('/').any(|seg| {
                matches!(
                    seg,
                    "node_modules" | "target" | "build" | "dist" | "vendor" | ".build"
                )
            })
        })
        .collect();
    out.sort();
    out
}

pub fn scan(root: &Path, focus: Option<&Path>) -> Graph {
    let files = source_files(root, focus);
    let set: HashSet<&str> = files.iter().map(String::as_str).collect();
    let mut g = Graph {
        files: files.clone(),
        ..Default::default()
    };
    let texts: HashMap<&str, String> = files
        .iter()
        .filter_map(|f| {
            std::fs::read_to_string(root.join(f))
                .ok()
                .map(|t| (f.as_str(), t))
        })
        .collect();

    let rust = RustModules::new(root, &files);
    let swift_types = swift_declarations(root, &texts);
    let go_module = std::fs::read_to_string(root.join("go.mod"))
        .ok()
        .and_then(|m| {
            m.lines()
                .find_map(|l| l.strip_prefix("module ").map(|s| s.trim().to_string()))
        });

    for f in &files {
        let Some(text) = texts.get(f.as_str()) else {
            continue;
        };
        let ext = Path::new(f)
            .extension()
            .and_then(|x| x.to_str())
            .unwrap_or("");
        let targets: Vec<String> = match ext {
            "rs" => rust.references(f, text),
            "ts" | "tsx" | "js" | "jsx" | "mjs" => js_imports(f, text, &set),
            "py" => py_imports(f, text, &set),
            "go" => go_imports(text, go_module.as_deref(), &files),
            "swift" => swift_references(root, f, text, &swift_types),
            _ => Vec::new(),
        };
        for t in targets {
            if &t != f && set.contains(t.as_str()) {
                *g.edges.entry((f.clone(), t)).or_default() += 1;
            }
        }
    }
    g
}

/// Rust: a module tree per crate (from `mod` declarations), resolving `crate::a::b`,
/// `super::x`, `self::x` and `other_crate::a` paths to files.
struct RustModules {
    /// crate name (underscored) -> module path ("" is the root) -> file
    crates: HashMap<String, HashMap<String, String>>,
    /// file -> (crate name, module path)
    owner: HashMap<String, (String, String)>,
}

static RS_PATH: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b(crate|super|self|[a-z_][a-z0-9_]*)((?:::[A-Za-z_][A-Za-z0-9_]*)+)").unwrap()
});
static RS_MOD: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+([a-z_][a-z0-9_]*)\s*;").unwrap()
});

impl RustModules {
    fn new(root: &Path, files: &[String]) -> Self {
        let mut crates = HashMap::new();
        let mut owner = HashMap::new();
        let set: HashSet<&str> = files.iter().map(String::as_str).collect();
        // Crate roots: src/lib.rs, src/main.rs (and src/bin/*.rs as their own crates).
        let roots: Vec<&String> = files
            .iter()
            .filter(|f| {
                f.ends_with("src/lib.rs") || f.ends_with("src/main.rs") || f.contains("src/bin/")
            })
            .collect();
        for r in roots {
            let crate_dir = r.split("src/").next().unwrap_or("");
            let name = crate_name(root, crate_dir, r);
            let mut modules: HashMap<String, String> = HashMap::new();
            let mut stack = vec![(r.clone(), String::new())];
            while let Some((file, path)) = stack.pop() {
                if modules.contains_key(&path) {
                    continue;
                }
                modules.insert(path.clone(), file.clone());
                owner
                    .entry(file.clone())
                    .or_insert_with(|| (name.clone(), path.clone()));
                let Ok(text) = std::fs::read_to_string(root.join(&file)) else {
                    continue;
                };
                // Children live beside a mod.rs/lib.rs/main.rs, else in a dir named after the file.
                let base = Path::new(&file);
                let stem = base.file_stem().and_then(|s| s.to_str()).unwrap_or("");
                let dir = if matches!(stem, "mod" | "lib" | "main") || file.contains("src/bin/") {
                    base.parent().map(Path::to_path_buf).unwrap_or_default()
                } else {
                    base.parent().unwrap_or(Path::new("")).join(stem)
                };
                for m in RS_MOD.captures_iter(&text) {
                    let child = &m[1];
                    for cand in [
                        dir.join(format!("{child}.rs")),
                        dir.join(child).join("mod.rs"),
                    ] {
                        let c = cand.to_string_lossy().into_owned();
                        if set.contains(c.as_str()) {
                            let p = if path.is_empty() {
                                child.to_string()
                            } else {
                                format!("{path}::{child}")
                            };
                            stack.push((c, p));
                            break;
                        }
                    }
                }
            }
            crates.insert(name, modules);
        }
        Self { crates, owner }
    }

    fn references(&self, file: &str, text: &str) -> Vec<String> {
        let Some((krate, here)) = self.owner.get(file) else {
            return Vec::new();
        };
        // (`mod x;` declarations are structure, not dependency; the map shows structure as
        // groups, and counting them would make every crate root a hub.)
        let mut out = Vec::new();
        for c in RS_PATH.captures_iter(text) {
            let head = &c[1];
            let rest: Vec<&str> = c[2].split("::").filter(|s| !s.is_empty()).collect();
            let child = || {
                let mut b = split(here);
                b.push(head.to_string());
                b
            };
            let (target_crate, mut base): (&str, Vec<String>) = match head {
                "crate" => (krate.as_str(), Vec::new()),
                "self" => (krate.as_str(), split(here)),
                "super" => {
                    let mut b = split(here);
                    b.pop();
                    (krate.as_str(), b)
                }
                other if self.crates.contains_key(other) && other != krate => (other, Vec::new()),
                // `store::Store` from the parent of `store` (2018-edition relative path).
                _ if self
                    .crates
                    .get(krate)
                    .is_some_and(|m| m.contains_key(&child().join("::"))) =>
                {
                    (krate.as_str(), child())
                }
                _ => continue,
            };
            if let Some(f) = self
                .crates
                .get(target_crate)
                .and_then(|m| m.get(&base.join("::")))
                && !base.is_empty()
                && head != "super"
                && head != "self"
                && head != "crate"
            {
                out.push(f.clone());
            }
            let Some(modules) = self.crates.get(target_crate) else {
                continue;
            };
            // The longest prefix of the path that names a module.
            let mut best = None;
            for seg in &rest {
                base.push(seg.to_string());
                if let Some(f) = modules.get(&base.join("::")) {
                    best = Some(f.clone());
                }
            }
            if best.is_none() && head != "crate" && head != "self" && head != "super" {
                best = modules.get("").cloned(); // another crate's root
            }
            if let Some(f) = best {
                out.push(f);
            }
        }
        out
    }
}

fn split(path: &str) -> Vec<String> {
    path.split("::")
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect()
}

fn crate_name(root: &Path, crate_dir: &str, root_file: &str) -> String {
    if root_file.contains("src/bin/") {
        return Path::new(root_file)
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("bin")
            .replace('-', "_");
    }
    let toml = std::fs::read_to_string(root.join(crate_dir).join("Cargo.toml")).unwrap_or_default();
    let mut in_package = false;
    for line in toml.lines() {
        let l = line.trim();
        if l.starts_with('[') {
            in_package = l == "[package]";
        } else if in_package
            && l.starts_with("name")
            && let Some(v) = l.split('=').nth(1)
        {
            return v.trim().trim_matches('"').replace('-', "_");
        }
    }
    Path::new(crate_dir)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("crate")
        .replace('-', "_")
}

static JS_IMPORT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?:from\s+|require\(\s*|import\(\s*|import\s+)['"](\.{1,2}/[^'"]+)['"]"#).unwrap()
});

fn js_imports(file: &str, text: &str, files: &HashSet<&str>) -> Vec<String> {
    let dir = Path::new(file).parent().unwrap_or(Path::new(""));
    JS_IMPORT
        .captures_iter(text)
        .filter_map(|c| {
            let base = normalize(&dir.join(&c[1]));
            let candidates = [
                base.clone(),
                format!("{base}.ts"),
                format!("{base}.tsx"),
                format!("{base}.js"),
                format!("{base}.jsx"),
                format!("{base}/index.ts"),
                format!("{base}/index.tsx"),
                format!("{base}/index.js"),
            ];
            candidates.into_iter().find(|c| files.contains(c.as_str()))
        })
        .collect()
}

static PY_FROM: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^\s*from\s+(\.*)([A-Za-z0-9_\.]*)\s+import\s+([A-Za-z0-9_, ]+)").unwrap()
});
static PY_IMPORT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^\s*import\s+([A-Za-z0-9_\.]+)").unwrap());

fn py_imports(file: &str, text: &str, files: &HashSet<&str>) -> Vec<String> {
    let dir = Path::new(file)
        .parent()
        .unwrap_or(Path::new(""))
        .to_path_buf();
    // Candidate package roots: every ancestor of this file (for absolute imports).
    let ancestors: Vec<PathBuf> = dir.ancestors().map(Path::to_path_buf).collect();
    let resolve = |base: &Path, dotted: &str| -> Option<String> {
        let rel = dotted.replace('.', "/");
        let p = if rel.is_empty() {
            base.to_path_buf()
        } else {
            base.join(&rel)
        };
        let p = normalize(&p);
        [format!("{p}.py"), format!("{p}/__init__.py")]
            .into_iter()
            .find(|c| files.contains(c.as_str()))
    };
    let mut out = Vec::new();
    for c in PY_FROM.captures_iter(text) {
        let dots = c[1].len();
        let module = &c[2];
        if dots > 0 {
            let mut base = dir.clone();
            for _ in 1..dots {
                base.pop();
            }
            // `from . import a, b` names modules; `from .x import y` names module x.
            if module.is_empty() {
                out.extend(c[3].split(',').filter_map(|n| resolve(&base, n.trim())));
            } else if let Some(f) = resolve(&base, module) {
                out.push(f);
            }
        } else {
            out.extend(ancestors.iter().find_map(|a| resolve(a, module)));
        }
    }
    for c in PY_IMPORT.captures_iter(text) {
        out.extend(ancestors.iter().find_map(|a| resolve(a, &c[1])));
    }
    out
}

static GO_IMPORT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""([^"\s]+)""#).unwrap());

fn go_imports(text: &str, module: Option<&str>, files: &[String]) -> Vec<String> {
    let Some(module) = module else {
        return Vec::new();
    };
    // Only the import block(s).
    let mut out = Vec::new();
    for block in text.split("import").skip(1).take(4) {
        let block = block.split(')').next().unwrap_or(block);
        for c in GO_IMPORT.captures_iter(block) {
            if let Some(rel) = c[1].strip_prefix(module).map(|r| r.trim_start_matches('/')) {
                // A package is a directory: link to its first file.
                if let Some(f) = files
                    .iter()
                    .find(|f| Path::new(f).parent() == Some(Path::new(rel)) && f.ends_with(".go"))
                {
                    out.push(f.clone());
                }
            }
        }
    }
    out
}

static SWIFT_DECL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^\s*(?:(?:public|private|fileprivate|internal|final|open|@MainActor)\s+)*(?:struct|class|enum|actor|protocol)\s+([A-Z][A-Za-z0-9_]*)").unwrap()
});
static WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b[A-Z][A-Za-z0-9_]*\b").unwrap());

/// A Swift file's module: the nearest ancestor with a Package.swift or an XcodeGen/Xcode
/// project, so type references don't link across separate apps or packages.
fn swift_module(root: &Path, file: &str) -> String {
    for dir in Path::new(file).ancestors().skip(1) {
        let abs = root.join(dir);
        if abs.join("Package.swift").exists() || abs.join("project.yml").exists() {
            return dir.to_string_lossy().into_owned();
        }
    }
    file.split('/').next().unwrap_or("").to_string()
}

/// (module, type name) -> declaring file.
fn swift_declarations(
    root: &Path,
    texts: &HashMap<&str, String>,
) -> HashMap<(String, String), String> {
    let mut decl = HashMap::new();
    for (f, t) in texts {
        if !f.ends_with(".swift") {
            continue;
        }
        let module = swift_module(root, f);
        for c in SWIFT_DECL.captures_iter(t) {
            decl.entry((module.clone(), c[1].to_string()))
                .or_insert_with(|| f.to_string());
        }
    }
    decl
}

/// Swift files in a module see each other without imports; link a file to the files that
/// declare the types it mentions.
fn swift_references(
    root: &Path,
    file: &str,
    text: &str,
    decl: &HashMap<(String, String), String>,
) -> Vec<String> {
    let module = swift_module(root, file);
    let mut seen = HashSet::new();
    WORD.find_iter(text)
        .filter_map(|m| decl.get(&(module.clone(), m.as_str().to_string())))
        .filter(|f| f.as_str() != file && seen.insert(f.as_str()))
        .cloned()
        .collect()
}

fn normalize(p: &Path) -> String {
    let mut out: Vec<String> = Vec::new();
    for c in p.components() {
        match c {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            c => out.push(c.as_os_str().to_string_lossy().into_owned()),
        }
    }
    out.join("/")
}

// MARK: - Churn

/// Commits touching each file in the last 90 days.
pub fn churn(root: &Path) -> HashMap<String, usize> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        // --relative: paths relative to `root`, like the map's (root may be inside the repo).
        .args([
            "log",
            "--since=90.days",
            "--name-only",
            "--relative",
            "--format=",
        ])
        .output();
    let mut counts = HashMap::new();
    if let Ok(o) = out {
        for line in String::from_utf8_lossy(&o.stdout).lines() {
            let l = line.trim();
            if !l.is_empty() {
                *counts.entry(l.to_string()).or_default() += 1;
            }
        }
    }
    counts
}

// MARK: - Diagram

/// Collapse `path` to its first `depth` components.
fn prefix(path: &str, depth: usize) -> String {
    path.split('/').take(depth).collect::<Vec<_>>().join("/")
}

fn to_diagram(root: &Path, g: &Graph, churn: &HashMap<String, usize>, opts: &Options) -> Diagram {
    let title = format!(
        "{} map",
        opts.focus
            .as_ref()
            .map(|f| f.display().to_string())
            .unwrap_or_else(|| root
                .file_name()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default())
    );
    let mut d = Diagram {
        kind: Kind::Flow,
        title,
        direction: Direction::Down,
        ..Default::default()
    };
    if g.files.is_empty() {
        return d;
    }
    // Pick the deepest granularity that fits: files, or directories cut at some depth. Only
    // files that take part in an edge count, so leaf utilities don't crowd the map.
    let linked: HashSet<&str> = g
        .edges
        .keys()
        .flat_map(|(a, b)| [a.as_str(), b.as_str()])
        .collect();
    let depth_max = g
        .files
        .iter()
        .map(|f| f.split('/').count())
        .max()
        .unwrap_or(1);
    let mut depth = depth_max;
    let unit = |f: &str, depth: usize| -> String {
        if f.split('/').count() <= depth {
            f.to_string()
        } else {
            prefix(f, depth)
        }
    };
    while depth > 1 {
        let n: HashSet<String> = linked.iter().map(|f| unit(f, depth)).collect();
        if n.len() <= opts.max_nodes {
            break;
        }
        depth -= 1;
    }
    let mut units: BTreeMap<String, Vec<&str>> = BTreeMap::new();
    for f in &linked {
        units.entry(unit(f, depth)).or_default().push(f);
    }
    let mut edges: BTreeMap<(String, String), usize> = BTreeMap::new();
    for ((a, b), n) in &g.edges {
        let (ua, ub) = (unit(a, depth), unit(b, depth));
        if ua != ub {
            *edges.entry((ua, ub)).or_default() += n;
        }
    }
    let max_churn = units
        .values()
        .map(|fs| {
            fs.iter()
                .map(|f| churn.get(*f).copied().unwrap_or(0))
                .sum::<usize>()
        })
        .max()
        .unwrap_or(0)
        .max(1);
    // Shortest unique path suffix per unit (`frog-engine/src`, not two `src`s).
    let labels: HashMap<String, String> = {
        let keys: Vec<&String> = units.keys().collect();
        let suffix = |u: &str, k: usize| -> String {
            let parts: Vec<&str> = u.split('/').collect();
            parts[parts.len().saturating_sub(k)..].join("/")
        };
        keys.iter()
            .map(|u| {
                let depth = u.split('/').count();
                let k = (1..=depth)
                    .find(|&k| keys.iter().filter(|o| suffix(o, k) == suffix(u, k)).count() == 1)
                    .unwrap_or(depth);
                ((*u).clone(), suffix(u, k))
            })
            .collect()
    };
    // Units directly in the mapped directory aren't framed: that frame would hold nearly
    // everything and say nothing.
    // The deepest directory containing every unit.
    let top = {
        let mut common: Option<Vec<&str>> = None;
        for u in units.keys() {
            let dirs: Vec<&str> = u.split('/').collect();
            let dirs = &dirs[..dirs.len().saturating_sub(1)];
            common = Some(match common {
                None => dirs.to_vec(),
                Some(c) => c
                    .iter()
                    .zip(dirs)
                    .take_while(|(a, b)| a == b)
                    .map(|(a, _)| *a)
                    .collect(),
            });
        }
        common.unwrap_or_default().join("/")
    };
    let mut groups: BTreeMap<String, String> = BTreeMap::new();
    for (u, files) in &units {
        let is_file = files.len() == 1 && files[0] == u;
        let parent = Path::new(u)
            .parent()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
        let commits: usize = files
            .iter()
            .map(|f| churn.get(*f).copied().unwrap_or(0))
            .sum();
        let id = u.replace(['/', '.', '-'], "_");
        let group = (!parent.is_empty() && parent != top).then(|| {
            let gid = format!("g_{}", parent.replace(['/', '.', '-'], "_"));
            groups.entry(gid.clone()).or_insert(parent.clone());
            gid
        });
        let name = labels.get(u).cloned().unwrap_or_else(|| u.clone());
        let mut detail = if is_file {
            u.clone()
        } else {
            format!("{u}/ ({} files)", files.len())
        };
        if commits > 0 {
            detail.push_str(&format!(
                " · {commits} commit{} in 90 days",
                if commits == 1 { "" } else { "s" }
            ));
        }
        d.nodes.push(Node {
            id,
            label: if is_file { name } else { format!("{name}/") },
            group,
            file: Some(u.clone()),
            detail: Some(detail),
            heat: (commits > 0).then(|| commits as f32 / max_churn as f32),
            ..Default::default()
        });
    }
    // Groups with a single member add a frame without adding information.
    let mut members: HashMap<String, usize> = HashMap::new();
    for n in &d.nodes {
        if let Some(g) = &n.group {
            *members.entry(g.clone()).or_default() += 1;
        }
    }
    for n in &mut d.nodes {
        if n.group.as_ref().is_some_and(|g| members[g] < 2) {
            n.group = None;
        }
    }
    d.groups = groups
        .into_iter()
        .filter(|(id, _)| members.get(id).copied().unwrap_or(0) >= 2)
        .map(|(id, label)| Group { id, label })
        .collect();
    let heaviest = edges.values().copied().max().unwrap_or(1);
    for ((a, b), n) in edges {
        d.edges.push(Edge {
            from: a.replace(['/', '.', '-'], "_"),
            to: b.replace(['/', '.', '-'], "_"),
            label: None,
            style: if n * 3 >= heaviest * 2 && heaviest >= 3 {
                EdgeStyle::Thick
            } else {
                EdgeStyle::Solid
            },
        });
    }
    d
}

/// A compact text form for the model: each unit and what it depends on.
pub fn summary(d: &Diagram) -> String {
    let name = |id: &str| {
        d.nodes
            .iter()
            .find(|n| n.id == id)
            .and_then(|n| n.file.clone())
            .unwrap_or_else(|| id.into())
    };
    let mut out = format!(
        "{} ({} units, {} dependencies)\n",
        d.title,
        d.nodes.len(),
        d.edges.len()
    );
    for n in &d.nodes {
        let deps: Vec<String> = d
            .edges
            .iter()
            .filter(|e| e.from == n.id)
            .map(|e| name(&e.to))
            .collect();
        let hot = n
            .heat
            .map(|h| if h > 0.66 { " [hot]" } else { "" })
            .unwrap_or("");
        out.push_str(&format!("- {}{hot}", n.file.as_deref().unwrap_or(&n.label)));
        if !deps.is_empty() {
            out.push_str(&format!(" -> {}", deps.join(", ")));
        }
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project(files: &[(&str, &str)]) -> PathBuf {
        let root = std::env::temp_dir().join(format!("frog-map-{}", crate::session::new_id()));
        for (path, text) in files {
            let p = root.join(path);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, text).unwrap();
        }
        root
    }

    fn has(g: &Graph, a: &str, b: &str) -> bool {
        g.edges.contains_key(&(a.to_string(), b.to_string()))
    }

    #[test]
    fn rust_modules_and_workspace_crates() {
        let root = project(&[
            ("core/Cargo.toml", "[package]\nname = \"my-core\"\n"),
            (
                "core/src/lib.rs",
                "pub mod store;\nmod util;\npub use store::Store;\n",
            ),
            (
                "core/src/store.rs",
                "use crate::util::helper;\nuse super::util;\n",
            ),
            ("core/src/util/mod.rs", "pub mod fmt;\npub fn helper() {}\n"),
            (
                "core/src/util/fmt.rs",
                "pub fn f() { crate::store::x(); }\n",
            ),
            ("app/Cargo.toml", "[package]\nname = \"app\"\n"),
            (
                "app/src/main.rs",
                "use my_core::store::Store;\nfn main() {}\n",
            ),
        ]);
        let g = scan(&root, None);
        // `pub use store::Store` in lib.rs is a real reference; `mod store;` alone isn't.
        assert!(has(&g, "core/src/lib.rs", "core/src/store.rs"));
        assert!(has(&g, "core/src/store.rs", "core/src/util/mod.rs"));
        assert!(has(&g, "core/src/util/fmt.rs", "core/src/store.rs"));
        assert!(
            has(&g, "app/src/main.rs", "core/src/store.rs"),
            "{:?}",
            g.edges
        );
    }

    #[test]
    fn js_python_and_swift_references() {
        let root = project(&[
            (
                "web/src/app.ts",
                "import { api } from './lib/api';\nconst x = require('./util');\n",
            ),
            ("web/src/lib/api.ts", "export const api = 1;\n"),
            ("web/src/util/index.js", "module.exports = {};\n"),
            ("py/pkg/__init__.py", ""),
            (
                "py/pkg/models.py",
                "from .db import conn\nfrom . import helpers\n",
            ),
            ("py/pkg/db.py", "conn = 1\n"),
            ("py/pkg/helpers.py", "import pkg.db\n"),
            (
                "mac/Views/Card.swift",
                "struct Card: View { let item: Item }\n",
            ),
            ("mac/Model/Item.swift", "struct Item {}\n"),
        ]);
        let g = scan(&root, None);
        assert!(has(&g, "web/src/app.ts", "web/src/lib/api.ts"));
        assert!(has(&g, "web/src/app.ts", "web/src/util/index.js"));
        assert!(has(&g, "py/pkg/models.py", "py/pkg/db.py"));
        assert!(has(&g, "py/pkg/models.py", "py/pkg/helpers.py"));
        assert!(
            has(&g, "py/pkg/helpers.py", "py/pkg/db.py"),
            "{:?}",
            g.edges
        );
        assert!(has(&g, "mac/Views/Card.swift", "mac/Model/Item.swift"));
    }

    #[test]
    fn collapses_to_directories_when_there_are_too_many_files() {
        let mut files: Vec<(String, String)> = Vec::new();
        for m in 0..6 {
            for i in 0..8 {
                let next = if i == 7 {
                    String::new()
                } else {
                    format!("./f{}", i + 1)
                };
                let other = format!("../m{}/f0", (m + 1) % 6);
                let body = format!(
                    "import a from '{other}';\n{}",
                    if next.is_empty() {
                        String::new()
                    } else {
                        format!("import b from '{next}';\n")
                    }
                );
                files.push((format!("src/m{m}/f{i}.ts"), body));
            }
        }
        let refs: Vec<(&str, &str)> = files
            .iter()
            .map(|(a, b)| (a.as_str(), b.as_str()))
            .collect();
        let root = project(&refs);
        let mut d = map(
            &root,
            &Options {
                focus: None,
                max_nodes: 10,
            },
        );
        assert_eq!(
            d.nodes.len(),
            6,
            "{:?}",
            d.nodes.iter().map(|n| &n.label).collect::<Vec<_>>()
        );
        assert!(d.nodes.iter().all(|n| n.label.ends_with('/')));
        assert_eq!(d.edges.len(), 6);
        d.finish(&root);
        assert!(d.layout.is_some());
        assert!(summary(&d).contains("src/m0 -> src/m1"));
    }
}
