//! Diagrams: a small typed model (flow/architecture and sequence), validated against the
//! project, laid out here in the engine so every client draws the same picture: the Mac app
//! natively, the terminal in box-drawing characters. Mermaid converts in both directions.

use serde::{Deserialize, Serialize};
use schemars::JsonSchema;
use std::collections::{HashMap, HashSet};
use std::path::Path;

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// Boxes and arrows: architecture, data flow, control flow.
    #[default]
    Flow,
    /// Participants across the top, messages down the page in order.
    Sequence,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    #[default]
    Down,
    Right,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Shape {
    #[default]
    Box,
    Rounded,
    /// A database, cache or queue.
    Store,
    /// A person or external actor.
    Actor,
    Decision,
    /// Something outside the system (a third-party API).
    External,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum EdgeStyle {
    #[default]
    Solid,
    /// Async, optional, or (in sequences) a reply.
    Dashed,
    /// The main path.
    Thick,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, JsonSchema)]
pub struct Node {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub shape: Shape,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    /// Source file this node stands for, relative to the project.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    /// A sentence shown on hover.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// 0..1 activity (code maps: recent git churn), drawn as a warm tint.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub heat: Option<f32>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, JsonSchema)]
pub struct Edge {
    pub from: String,
    pub to: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default)]
    pub style: EdgeStyle,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, JsonSchema)]
pub struct Group {
    pub id: String,
    #[serde(default)]
    pub label: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, JsonSchema)]
pub struct Diagram {
    #[serde(default)]
    pub kind: Kind,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub direction: Direction,
    #[serde(default)]
    pub nodes: Vec<Node>,
    #[serde(default)]
    pub edges: Vec<Edge>,
    #[serde(default)]
    pub groups: Vec<Group>,
    /// Computed by [`Diagram::layout`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout: Option<Layout>,
    /// The compact form for the transcript column, computed by [`Diagram::finish`] when the full
    /// layout is too wide to read at the column's scale floor. Clients draw `inline` when present
    /// and `layout` when expanded (the pop-out, exports). Old transcripts without it still decode.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inline: Option<Layout>,
    /// The same diagram as Mermaid, for export.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub mermaid: String,
}

/// Positions in points, origin top-left.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, JsonSchema)]
pub struct Layout {
    pub width: f32,
    pub height: f32,
    pub nodes: Vec<NodeBox>,
    pub edges: Vec<EdgePath>,
    #[serde(default)]
    pub groups: Vec<GroupBox>,
    /// Sequence diagrams: where the lifelines end.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lifeline_end: Option<f32>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, JsonSchema)]
pub struct NodeBox {
    pub id: String,
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    /// Layer (flow) or column (sequence), for staggered reveal.
    pub rank: usize,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, JsonSchema)]
pub struct EdgePath {
    /// Index into `edges`.
    pub edge: usize,
    /// Polyline from source to target; clients may smooth it.
    pub points: Vec<[f32; 2]>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label_at: Option<[f32; 2]>,
    /// A bundle row: several consecutive messages folded into one (folded sequences only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle: Option<Bundle>,
}

/// A bundle row: several consecutive messages folded into one (folded sequences only). A bundle
/// has no single source edge, so clients must check `bundle` before reading `edge`.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, JsonSchema)]
pub struct Bundle {
    /// The lifeline the bundle sits on (a participant or folded group).
    pub lane: usize,
    /// How many messages were folded.
    pub count: usize,
    /// The numbers hoisted from the folded messages.
    #[serde(default)]
    pub label: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, JsonSchema)]
pub struct GroupBox {
    pub id: String,
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

const MAX_NODES: usize = 60;
const MAX_LABEL: usize = 60;

// The inline transcript column (720pt minus card padding) and the smallest scale its text may
// render at: 13pt node text never goes below ~11pt. Layouts wider than `INLINE_W / MIN_SCALE`
// don't fit, so the engine changes their form instead of shrinking them.
const INLINE_W: f32 = 704.0;
const MIN_SCALE: f32 = 0.85;
/// The most lanes (folded groups or participants) a sequence may use inline.
const MAX_INLINE_LANES: usize = 6;

/// One folded lane in the inline form of a sequence: a group (its members share the lane) or a
/// lone participant.
struct FoldLane {
    label: String,
    members: Vec<usize>,
}

/// A label that carries a measurement (`8 tok/s`, `1000+`, `40 ms`): bundles hoist it out of the
/// messages they fold so the numbers survive the fold.
fn carries_number(label: &str) -> bool {
    use std::sync::LazyLock;
    static NUMBER: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"\d[\d.,]*\s?(ms|s|µs|%|x|×|tok/s|GB|k)\b").unwrap()
    });
    NUMBER.is_match(label)
}

// MARK: - Validation

impl Diagram {
    /// Clean up what a model produced: ids, dangling edges (their nodes are created), labels,
    /// and `file` links (kept only if the file exists under `cwd`). Returns warnings for the
    /// model.
    pub fn prepare(&mut self, cwd: &Path) -> Vec<String> {
        self.inline = None;
        let mut warnings = Vec::new();
        self.title = self.title.trim().to_string();
        if self.nodes.len() > MAX_NODES {
            warnings.push(format!(
                "Kept the first {MAX_NODES} of {} nodes; split big diagrams into several.",
                self.nodes.len()
            ));
            self.nodes.truncate(MAX_NODES);
        }
        let mut seen = HashSet::new();
        for (i, n) in self.nodes.iter_mut().enumerate() {
            if n.id.trim().is_empty() {
                n.id = slug(&n.label).unwrap_or_else(|| format!("n{i}"));
            }
            n.id = n.id.trim().to_string();
            while !seen.insert(n.id.clone()) {
                n.id.push('_');
            }
            if n.label.trim().is_empty() {
                n.label = n.id.clone();
            }
            n.label = clip(n.label.trim(), MAX_LABEL);
            if let Some(f) = n.file.take() {
                let f = f.trim().trim_start_matches("./").to_string();
                let path = if Path::new(&f).is_absolute() {
                    f.clone().into()
                } else {
                    cwd.join(&f)
                };
                if path.exists() {
                    n.file = Some(f);
                } else {
                    warnings.push(format!(
                        "`{}`: file `{f}` doesn't exist, so it isn't linked.",
                        n.id
                    ));
                }
            }
        }
        let ids: HashSet<String> = self.nodes.iter().map(|n| n.id.clone()).collect();
        let mut added = Vec::new();
        for e in &mut self.edges {
            e.from = e.from.trim().to_string();
            e.to = e.to.trim().to_string();
            for end in [&e.from, &e.to] {
                if !ids.contains(end) && !added.contains(end) && !end.is_empty() {
                    added.push(end.clone());
                }
            }
            if let Some(l) = &e.label {
                let l = clip(l.trim(), MAX_LABEL);
                e.label = (!l.is_empty()).then_some(l);
            }
        }
        self.edges
            .retain(|e| !e.from.is_empty() && !e.to.is_empty());
        for id in added {
            self.nodes.push(Node {
                label: id.clone(),
                id,
                ..Default::default()
            });
        }
        let group_ids: HashSet<&str> = self.groups.iter().map(|g| g.id.as_str()).collect();
        let mut missing: Vec<String> = self
            .nodes
            .iter()
            .filter_map(|n| n.group.clone())
            .filter(|g| !group_ids.contains(g.as_str()))
            .collect();
        missing.sort();
        missing.dedup();
        for g in missing {
            self.groups.push(Group {
                label: g.clone(),
                id: g,
            });
        }
        for g in &mut self.groups {
            if g.label.is_empty() {
                g.label = g.id.clone();
            }
        }
        if self.nodes.is_empty() {
            warnings.push("The diagram has no nodes.".into());
        }
        warnings
    }

    /// Validate, lay out, and render the Mermaid version.
    pub fn finish(&mut self, cwd: &Path) -> Vec<String> {
        let w = self.prepare(cwd);
        let w = self.fit(w);
        self.layout = Some(self.layout());
        self.mermaid = self.to_mermaid();
        w
    }

    /// The fit pass: make sure the diagram reads at the transcript column (720pt) with the text
    /// no smaller than [`MIN_SCALE`]. The full layout stays untouched in `layout`; the compact
    /// form that does fit goes in `inline`. Warnings tell the model what was folded.
    fn fit(&mut self, mut warnings: Vec<String>) -> Vec<String> {
        let natural = self.layout();
        if natural.width * MIN_SCALE <= INLINE_W {
            return warnings; // It already reads at the column.
        }
        let candidate = match self.kind {
            Kind::Flow => {
                // A right-ward chain lays out too wide: try the same diagram top-down before
                // giving up on the inline form.
                if self.direction != Direction::Right {
                    None
                } else {
                    let mut down = self.clone();
                    down.direction = Direction::Down;
                    let l = down.layout();
                    (l.width * MIN_SCALE <= INLINE_W).then_some(l)
                }
            }
            Kind::Sequence => match self.foldable_lanes() {
                Some(lanes) if lanes.len() <= MAX_INLINE_LANES => {
                    let l = sequence_layout_folded(self, &lanes);
                    // Tell the model what's on screen, so its prose can refer to it.
                    let bundles = l.edges.iter().filter(|p| p.bundle.is_some()).count();
                    warnings.push(format!(
                        "Shown folded: {} participants in {} lanes, {} messages in {} rows{}.",
                        self.nodes.len(),
                        lanes.len(),
                        self.edges.len(),
                        l.edges.len(),
                        if bundles > 0 {
                            format!(" ({bundles} bundles)")
                        } else {
                            String::new()
                        }
                    ));
                    Some(l)
                }
                _ => {
                    warnings.push(format!(
                        "{} participants won't fit at 720pt. Give nodes a `group` (≤{MAX_INLINE_LANES} groups) or split the diagram.",
                        self.nodes.len()
                    ));
                    None
                }
            },
        };
        self.inline = candidate;
        warnings
    }

    /// Participants folded into lanes for the inline form: one per group (in declaration order),
    /// ungrouped participants stay individual. Only when every node has a group; with strays the
    /// fold wouldn't shrink below [`MAX_INLINE_LANES`] lanes, so no inline form is offered.
    fn foldable_lanes(&self) -> Option<Vec<FoldLane>> {
        if self.nodes.iter().any(|n| n.group.is_none()) {
            return None;
        }
        let mut lanes: Vec<FoldLane> = Vec::new();
        for g in &self.groups {
            let members: Vec<usize> = self
                .nodes
                .iter()
                .enumerate()
                .filter(|(_, n)| n.group.as_deref() == Some(&g.id))
                .map(|(i, _)| i)
                .collect();
            if !members.is_empty() {
                lanes.push(FoldLane {
                    label: g.label.clone(),
                    members,
                });
            }
        }
        (!lanes.is_empty()).then_some(lanes)
    }
}

fn clip(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    format!("{}…", s.chars().take(max - 1).collect::<String>())
}

fn slug(s: &str) -> Option<String> {
    let out: String = s
        .chars()
        .map(|c| {
            if c.is_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect::<String>()
        .trim_matches('_')
        .to_string();
    (!out.is_empty()).then_some(out)
}

// MARK: - Layout

/// Label wrapping and box size, in points (clients use ~13pt text).
const CHAR_W: f32 = 7.2;
const WRAP: usize = 24;
const LINE_H: f32 = 16.0;

pub fn wrap(label: &str) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    let mut cur = String::new();
    for word in label.split_whitespace() {
        if !cur.is_empty() && cur.chars().count() + 1 + word.chars().count() > WRAP {
            lines.push(std::mem::take(&mut cur));
        }
        if !cur.is_empty() {
            cur.push(' ');
        }
        cur.push_str(word);
    }
    if !cur.is_empty() {
        lines.push(cur);
    }
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines.truncate(3);
    lines
}

fn measure(n: &Node) -> (f32, f32) {
    let lines = wrap(&n.label);
    let widest = lines.iter().map(|l| l.chars().count()).max().unwrap_or(0) as f32;
    let (mut w, mut h) = (
        (widest * CHAR_W + 32.0).clamp(72.0, 240.0),
        20.0 + lines.len() as f32 * LINE_H,
    );
    // File caption, shown unless the label already names the file.
    if let Some(f) = &n.file {
        let name = Path::new(f)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(f);
        if !n.label.ends_with(name) || n.line.is_some() {
            h += 12.0;
        }
    }
    match n.shape {
        Shape::Decision => {
            w += 36.0;
            h += 20.0;
        }
        Shape::Store => h += 10.0,
        Shape::Actor => w += 20.0,
        _ => {}
    }
    (w, h)
}

impl Diagram {
    pub fn node_group(&self, id: &str) -> Option<&str> {
        self.nodes
            .iter()
            .find(|n| n.id == id)
            .and_then(|n| n.group.as_deref())
    }

    pub fn layout(&self) -> Layout {
        match self.kind {
            Kind::Flow => flow_layout(self),
            Kind::Sequence => sequence_layout(self),
        }
    }
}

const MARGIN: f32 = 24.0;

fn flow_layout(d: &Diagram) -> Layout {
    let n = d.nodes.len();
    if n == 0 {
        return Layout {
            width: 2.0 * MARGIN,
            height: 2.0 * MARGIN,
            ..Default::default()
        };
    }
    let index: HashMap<&str, usize> = d
        .nodes
        .iter()
        .enumerate()
        .map(|(i, n)| (n.id.as_str(), i))
        .collect();
    let right = d.direction == Direction::Right;
    // Sizes along (cross, main) axes: main runs from layer to layer.
    let sizes: Vec<(f32, f32)> = d
        .nodes
        .iter()
        .map(|n| {
            let (w, h) = measure(n);
            if right { (h, w) } else { (w, h) }
        })
        .collect();

    // Edges between known nodes, self-loops dropped from layering.
    let edges: Vec<(usize, usize, usize)> = d
        .edges
        .iter()
        .enumerate()
        .filter_map(|(k, e)| Some((k, *index.get(e.from.as_str())?, *index.get(e.to.as_str())?)))
        .collect();

    // 1. Break cycles: DFS, reversing edges that point back into the current path.
    let mut adj: Vec<Vec<(usize, usize)>> = vec![Vec::new(); n];
    for &(k, a, b) in &edges {
        if a != b {
            adj[a].push((b, k));
        }
    }
    let mut reversed = HashSet::new();
    let mut state = vec![0u8; n]; // 0 new, 1 on stack, 2 done
    fn dfs(v: usize, adj: &[Vec<(usize, usize)>], state: &mut [u8], rev: &mut HashSet<usize>) {
        state[v] = 1;
        for &(w, k) in &adj[v] {
            match state[w] {
                0 => dfs(w, adj, state, rev),
                1 => {
                    rev.insert(k);
                }
                _ => {}
            }
        }
        state[v] = 2;
    }
    for v in 0..n {
        if state[v] == 0 {
            dfs(v, &adj, &mut state, &mut reversed);
        }
    }
    let dag: Vec<(usize, usize, usize)> = edges
        .iter()
        .filter(|(_, a, b)| a != b)
        .map(|&(k, a, b)| {
            if reversed.contains(&k) {
                (k, b, a)
            } else {
                (k, a, b)
            }
        })
        .collect();

    // 2. Layers: longest path from the sources.
    let mut layer = vec![0usize; n];
    for _ in 0..n {
        let mut changed = false;
        for &(_, a, b) in &dag {
            if layer[b] < layer[a] + 1 {
                layer[b] = layer[a] + 1;
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }

    // 3. Dummy nodes so every edge spans one layer.
    //    Vertices: 0..n real, then dummies. chains[k] = vertex path for edge k.
    let mut v_layer = layer.clone();
    let mut v_size = sizes.clone();
    let mut v_group: Vec<Option<usize>> = d
        .nodes
        .iter()
        .map(|nd| {
            nd.group
                .as_ref()
                .and_then(|g| d.groups.iter().position(|x| &x.id == g))
        })
        .collect();
    let mut chains: HashMap<usize, Vec<usize>> = HashMap::new();
    let mut links: Vec<(usize, usize)> = Vec::new();
    for &(k, a, b) in &dag {
        let mut path = vec![a];
        let mut prev = a;
        for l in layer[a] + 1..layer[b] {
            let dmy = v_layer.len();
            v_layer.push(l);
            v_size.push((8.0, 8.0));
            v_group.push(None);
            links.push((prev, dmy));
            path.push(dmy);
            prev = dmy;
        }
        links.push((prev, b));
        path.push(b);
        chains.insert(k, path);
    }
    let vn = v_layer.len();
    let layers = v_layer.iter().max().copied().unwrap_or(0) + 1;
    let mut up: Vec<Vec<usize>> = vec![Vec::new(); vn];
    let mut down: Vec<Vec<usize>> = vec![Vec::new(); vn];
    for &(a, b) in &links {
        down[a].push(b);
        up[b].push(a);
    }

    // 4. Order within layers: start in declaration order, then barycenter sweeps. Grouped
    //    nodes sort by their group's average so groups stay together.
    let mut order: Vec<Vec<usize>> = vec![Vec::new(); layers];
    for v in 0..vn {
        order[v_layer[v]].push(v);
    }
    let mut pos = vec![0f32; vn];
    let reindex = |order: &Vec<Vec<usize>>, pos: &mut Vec<f32>| {
        for row in order {
            for (i, &v) in row.iter().enumerate() {
                pos[v] = i as f32;
            }
        }
    };
    reindex(&order, &mut pos);
    for sweep in 0..12 {
        let downward = sweep % 2 == 0;
        let range: Vec<usize> = if downward {
            (1..layers).collect()
        } else {
            (0..layers.saturating_sub(1)).rev().collect()
        };
        for l in range {
            let mut key: HashMap<usize, f32> = HashMap::new();
            for &v in &order[l] {
                let nb = if downward { &up[v] } else { &down[v] };
                let k = if nb.is_empty() {
                    pos[v]
                } else {
                    nb.iter().map(|&u| pos[u]).sum::<f32>() / nb.len() as f32
                };
                key.insert(v, k);
            }
            // Group cohesion: members share their group's mean key.
            let mut gsum: HashMap<usize, (f32, f32)> = HashMap::new();
            for &v in &order[l] {
                if let Some(g) = v_group[v] {
                    let e = gsum.entry(g).or_default();
                    e.0 += key[&v];
                    e.1 += 1.0;
                }
            }
            let mut row = order[l].clone();
            row.sort_by(|&a, &b| {
                let ka = v_group[a]
                    .map(|g| gsum[&g].0 / gsum[&g].1)
                    .unwrap_or(key[&a]);
                let kb = v_group[b]
                    .map(|g| gsum[&g].0 / gsum[&g].1)
                    .unwrap_or(key[&b]);
                ka.total_cmp(&kb)
                    .then(v_group[a].cmp(&v_group[b]))
                    .then(key[&a].total_cmp(&key[&b]))
            });
            order[l] = row;
            reindex(&order, &mut pos);
        }
    }

    // 5. Coordinates. Main axis: layers stacked with a gap. Cross axis: pack each layer, then
    //    pull nodes toward their neighbors' median while keeping order and spacing.
    const LAYER_GAP: f32 = 60.0;
    const NODE_GAP: f32 = 28.0;
    let mut main_at = vec![0f32; layers];
    let mut layer_depth = vec![0f32; layers];
    let mut acc = MARGIN;
    for l in 0..layers {
        let depth = order[l].iter().map(|&v| v_size[v].1).fold(0f32, f32::max);
        main_at[l] = acc;
        layer_depth[l] = depth;
        acc += depth + LAYER_GAP;
    }
    let gap = |a: usize, b: usize| -> f32 {
        let dummy = a >= n || b >= n;
        let base = if dummy { NODE_GAP / 2.0 } else { NODE_GAP };
        // Extra room between different groups, for their frames.
        if v_group[a] != v_group[b] && (v_group[a].is_some() || v_group[b].is_some()) {
            base + 24.0
        } else {
            base
        }
    };
    let mut cross = vec![0f32; vn]; // center on the cross axis
    for row in &order {
        let mut x = MARGIN;
        for (i, &v) in row.iter().enumerate() {
            if i > 0 {
                x += gap(row[i - 1], v);
            }
            cross[v] = x + v_size[v].0 / 2.0;
            x += v_size[v].0;
        }
    }
    for pass in 0..16 {
        let downward = pass % 2 == 0;
        let range: Vec<usize> = if downward {
            (0..layers).collect()
        } else {
            (0..layers).rev().collect()
        };
        for l in range {
            let row = order[l].clone();
            let want: Vec<f32> = row
                .iter()
                .map(|&v| {
                    let mut nb: Vec<f32> = up[v]
                        .iter()
                        .chain(down[v].iter())
                        .map(|&u| cross[u])
                        .collect();
                    if nb.is_empty() {
                        return cross[v];
                    }
                    nb.sort_by(f32::total_cmp);
                    let m = nb.len();
                    if m % 2 == 1 {
                        nb[m / 2]
                    } else {
                        (nb[m / 2 - 1] + nb[m / 2]) / 2.0
                    }
                })
                .collect();
            // Place left to right at the wanted spot or as far left as spacing allows, then
            // right to left, averaging the two to stay balanced.
            let mut left = vec![0f32; row.len()];
            for i in 0..row.len() {
                let v = row[i];
                let min = if i == 0 {
                    MARGIN + v_size[v].0 / 2.0
                } else {
                    left[i - 1]
                        + v_size[row[i - 1]].0 / 2.0
                        + gap(row[i - 1], v)
                        + v_size[v].0 / 2.0
                };
                left[i] = want[i].max(min);
            }
            let mut rightp = left.clone();
            for i in (0..row.len().saturating_sub(1)).rev() {
                let (v, w) = (row[i], row[i + 1]);
                let max = rightp[i + 1] - v_size[w].0 / 2.0 - gap(v, w) - v_size[v].0 / 2.0;
                rightp[i] = rightp[i].min(max).max(if i == 0 {
                    MARGIN + v_size[v].0 / 2.0
                } else {
                    f32::MIN
                });
            }
            for (i, &v) in row.iter().enumerate() {
                cross[v] = (left[i] + rightp[i]) / 2.0;
            }
            // Re-enforce spacing after averaging.
            for i in 1..row.len() {
                let (a, b) = (row[i - 1], row[i]);
                let min = cross[a] + v_size[a].0 / 2.0 + gap(a, b) + v_size[b].0 / 2.0;
                if cross[b] < min {
                    cross[b] = min;
                }
            }
        }
    }
    // 5b. Keep non-members out of group frames. A frame spans its members across layers, so
    //     in any layer it covers, a node that isn't a member is pushed past the frame's edge,
    //     along with everything further out in its row.
    const FRAME_PAD: f32 = 14.0;
    for gi in 0..d.groups.len() {
        let members: Vec<usize> = (0..n).filter(|&v| v_group[v] == Some(gi)).collect();
        if members.is_empty() {
            continue;
        }
        let lo_l = members.iter().map(|&v| v_layer[v]).min().unwrap();
        let hi_l = members.iter().map(|&v| v_layer[v]).max().unwrap();
        for row in order.iter().take(hi_l + 1).skip(lo_l) {
            let cmin = members
                .iter()
                .map(|&v| cross[v] - v_size[v].0 / 2.0)
                .fold(f32::MAX, f32::min)
                - FRAME_PAD;
            let cmax = members
                .iter()
                .map(|&v| cross[v] + v_size[v].0 / 2.0)
                .fold(f32::MIN, f32::max)
                + FRAME_PAD;
            let row = row.clone();
            for (i, &v) in row.iter().enumerate() {
                if v >= n || v_group[v] == Some(gi) {
                    continue;
                }
                let (lo, hi) = (cross[v] - v_size[v].0 / 2.0, cross[v] + v_size[v].0 / 2.0);
                if hi <= cmin - NODE_GAP / 2.0 || lo >= cmax + NODE_GAP / 2.0 {
                    continue;
                }
                if cross[v] < (cmin + cmax) / 2.0 {
                    let delta = hi - (cmin - NODE_GAP / 2.0);
                    for &u in &row[..=i] {
                        cross[u] -= delta;
                    }
                } else {
                    let delta = (cmax + NODE_GAP / 2.0) - lo;
                    for &u in &row[i..] {
                        cross[u] += delta;
                    }
                }
            }
        }
    }
    let min_cross = (0..vn)
        .map(|v| cross[v] - v_size[v].0 / 2.0)
        .fold(f32::MAX, f32::min);
    for c in &mut cross {
        *c += MARGIN - min_cross;
    }

    // Center of each vertex in (cross, main).
    let center = |v: usize| -> (f32, f32) {
        (
            cross[v],
            main_at[v_layer[v]] + layer_depth[v_layer[v]] / 2.0,
        )
    };
    let to_xy = |c: f32, m: f32| -> [f32; 2] { if right { [m, c] } else { [c, m] } };

    let mut nodes = Vec::with_capacity(n);
    for (i, nd) in d.nodes.iter().enumerate() {
        let (c, m) = center(i);
        let (cw, mh) = sizes[i];
        let [x, y] = to_xy(c - cw / 2.0, m - mh / 2.0);
        let (w, h) = if right { (mh, cw) } else { (cw, mh) };
        nodes.push(NodeBox {
            id: nd.id.clone(),
            x,
            y,
            w,
            h,
            rank: layer[i],
        });
    }

    // 6. Edge routes: leave the source's far side, pass through dummies, enter the target's
    //    near side. Reversed (cycle) edges are drawn back in their real direction.
    let mut paths = Vec::new();
    for &(k, a, b) in &edges {
        if a == b {
            // Self-loop: out and back on the outer side.
            let (c, m) = center(a);
            let (cw, mh) = sizes[a];
            let pts = vec![
                to_xy(c + cw / 2.0, m - mh / 4.0),
                to_xy(c + cw / 2.0 + 24.0, m - mh / 4.0),
                to_xy(c + cw / 2.0 + 24.0, m + mh / 4.0),
                to_xy(c + cw / 2.0, m + mh / 4.0),
            ];
            paths.push(EdgePath {
                edge: k,
                label_at: Some(to_xy(c + cw / 2.0 + 30.0, m)),
                points: pts,
                bundle: None,
            });
            continue;
        }
        // Parallel edges (same pair, either direction) fan out side by side.
        let pair = (a.min(b), a.max(b));
        let siblings: Vec<usize> = edges
            .iter()
            .filter(|&&(_, x, y)| (x.min(y), x.max(y)) == pair)
            .map(|&(k2, _, _)| k2)
            .collect();
        let slot = siblings.iter().position(|&k2| k2 == k).unwrap_or(0) as f32;
        let fan = (slot - (siblings.len() as f32 - 1.0) / 2.0) * 16.0;
        let chain = chains.get(&k).cloned().unwrap_or_else(|| vec![a, b]);
        let (from, to) = (chain[0], *chain.last().unwrap());
        let mut pts = Vec::new();
        let (fc, fm) = center(from);
        pts.push(to_xy(fc + fan, fm + v_size[from].1 / 2.0));
        for &v in &chain[1..chain.len() - 1] {
            let (c, m) = center(v);
            pts.push(to_xy(c + fan, m));
        }
        let (tc, tm) = center(to);
        pts.push(to_xy(tc + fan, tm - v_size[to].1 / 2.0));
        if reversed.contains(&k) {
            pts.reverse();
        }
        // Parallel edges' labels sit at staggered points along their paths so they don't
        // stack on the shared midpoint.
        // Measured in one direction for the whole pair, so opposite edges don't cancel out.
        let t = 0.5 + (slot - (siblings.len() as f32 - 1.0) / 2.0) * 0.3;
        let t = if a <= b { t } else { 1.0 - t };
        let label_at = d.edges[k]
            .label
            .as_ref()
            .map(|_| point_along(&pts, t.clamp(0.2, 0.8)));
        paths.push(EdgePath {
            edge: k,
            points: pts,
            label_at,
            bundle: None,
        });
    }

    // 7. Group frames around their members.
    let mut groups = Vec::new();
    for g in &d.groups {
        let members: Vec<&NodeBox> = d
            .nodes
            .iter()
            .zip(&nodes)
            .filter(|(nd, _)| nd.group.as_deref() == Some(&g.id))
            .map(|(_, b)| b)
            .collect();
        if members.is_empty() {
            continue;
        }
        let x0 = members.iter().map(|b| b.x).fold(f32::MAX, f32::min) - 14.0;
        let y0 = members.iter().map(|b| b.y).fold(f32::MAX, f32::min) - 30.0;
        let x1 = members.iter().map(|b| b.x + b.w).fold(f32::MIN, f32::max) + 14.0;
        let y1 = members.iter().map(|b| b.y + b.h).fold(f32::MIN, f32::max) + 14.0;
        groups.push(GroupBox {
            id: g.id.clone(),
            x: x0,
            y: y0,
            w: x1 - x0,
            h: y1 - y0,
        });
    }

    // Shift so group frames (which extend above/left of nodes) stay inside the margin.
    // Edge routes count too: they bend through spacer points that can lie outside the nodes.
    let route_xs = || paths.iter().flat_map(|p| p.points.iter().map(|q| q[0]));
    let route_ys = || paths.iter().flat_map(|p| p.points.iter().map(|q| q[1]));
    let min_x = nodes
        .iter()
        .map(|b| b.x)
        .chain(groups.iter().map(|g| g.x))
        .chain(route_xs())
        .fold(f32::MAX, f32::min);
    let min_y = nodes
        .iter()
        .map(|b| b.y)
        .chain(groups.iter().map(|g| g.y))
        .chain(route_ys())
        .fold(f32::MAX, f32::min);
    let (dx, dy) = (MARGIN - min_x, MARGIN - min_y);
    for b in &mut nodes {
        b.x += dx;
        b.y += dy;
    }
    for g in &mut groups {
        g.x += dx;
        g.y += dy;
    }
    for p in &mut paths {
        for pt in &mut p.points {
            pt[0] += dx;
            pt[1] += dy;
        }
        if let Some(l) = &mut p.label_at {
            l[0] += dx;
            l[1] += dy;
        }
    }
    let width = nodes
        .iter()
        .map(|b| b.x + b.w)
        .chain(groups.iter().map(|g| g.x + g.w))
        .chain(
            paths
                .iter()
                .flat_map(|p| p.points.iter().map(|q| q[0] + 8.0)),
        )
        .fold(0f32, f32::max)
        + MARGIN;
    let height = nodes
        .iter()
        .map(|b| b.y + b.h)
        .chain(groups.iter().map(|g| g.y + g.h))
        .chain(
            paths
                .iter()
                .flat_map(|p| p.points.iter().map(|q| q[1] + 8.0)),
        )
        .fold(0f32, f32::max)
        + MARGIN;
    Layout {
        width,
        height,
        nodes,
        edges: paths,
        groups,
        lifeline_end: None,
    }
}

/// The point a fraction `t` of the way along a polyline.
fn point_along(pts: &[[f32; 2]], t: f32) -> [f32; 2] {
    let seg = |a: [f32; 2], b: [f32; 2]| ((b[0] - a[0]).powi(2) + (b[1] - a[1]).powi(2)).sqrt();
    let total: f32 = pts.windows(2).map(|w| seg(w[0], w[1])).sum();
    let mut left = total * t;
    for w in pts.windows(2) {
        let l = seg(w[0], w[1]);
        if left <= l && l > 0.0 {
            let f = left / l;
            return [
                w[0][0] + (w[1][0] - w[0][0]) * f,
                w[0][1] + (w[1][1] - w[0][1]) * f,
            ];
        }
        left -= l;
    }
    *pts.last().unwrap_or(&[0.0, 0.0])
}

fn sequence_layout(d: &Diagram) -> Layout {
    let n = d.nodes.len();
    let index: HashMap<&str, usize> = d
        .nodes
        .iter()
        .enumerate()
        .map(|(i, n)| (n.id.as_str(), i))
        .collect();
    let sizes: Vec<(f32, f32)> = d.nodes.iter().map(measure).collect();
    // Column spacing: participants side by side, widened where a message label between two
    // neighbors needs the room.
    let mut need = vec![0f32; n.saturating_sub(1)];
    for e in &d.edges {
        let (Some(&a), Some(&b)) = (index.get(e.from.as_str()), index.get(e.to.as_str())) else {
            continue;
        };
        let (lo, hi) = (a.min(b), a.max(b));
        if lo == hi || hi - lo > 1 {
            continue;
        }
        let w = e
            .label
            .as_ref()
            .map(|l| l.chars().count() as f32 * CHAR_W + 32.0)
            .unwrap_or(60.0);
        need[lo] = need[lo].max(w);
    }
    // Compact columns: at least what the participant's own label needs, and 110pt minimum, but
    // no longer a fixed 150pt — six lanes stay under the 720pt column.
    let mut cx = vec![0f32; n];
    let mut x = MARGIN;
    for i in 0..n {
        if i == 0 {
            cx[i] = x + sizes[i].0 / 2.0;
        } else {
            let min = cx[i - 1] + sizes[i - 1].0 / 2.0 + 36.0 + sizes[i].0 / 2.0;
            let label_need = (sizes[i - 1].0 / 2.0 + sizes[i].0 / 2.0 + 36.0).max(110.0);
            cx[i] = min.max(cx[i - 1] + need[i - 1]).max(cx[i - 1] + label_need);
        }
        x = cx[i] + sizes[i].0 / 2.0;
    }
    let header = sizes.iter().map(|s| s.1).fold(0f32, f32::max);
    let nodes: Vec<NodeBox> = d
        .nodes
        .iter()
        .enumerate()
        .map(|(i, nd)| NodeBox {
            id: nd.id.clone(),
            x: cx[i] - sizes[i].0 / 2.0,
            y: MARGIN,
            w: sizes[i].0,
            h: header,
            rank: i,
        })
        .collect();
    let mut y = MARGIN + header + 34.0;
    let mut paths = Vec::new();
    for (k, e) in d.edges.iter().enumerate() {
        let (Some(&a), Some(&b)) = (index.get(e.from.as_str()), index.get(e.to.as_str())) else {
            continue;
        };
        if a == b {
            let x0 = cx[a];
            paths.push(EdgePath {
                edge: k,
                points: vec![
                    [x0, y],
                    [x0 + 36.0, y],
                    [x0 + 36.0, y + 18.0],
                    [x0, y + 18.0],
                ],
                label_at: e.label.as_ref().map(|_| [x0 + 44.0, y + 9.0]),
                bundle: None,
            });
            y += 48.0;
        } else {
            paths.push(EdgePath {
                edge: k,
                points: vec![[cx[a], y], [cx[b], y]],
                label_at: e.label.as_ref().map(|_| [(cx[a] + cx[b]) / 2.0, y - 10.0]),
                bundle: None,
            });
            y += 38.0;
        }
    }
    let end = y + 4.0;
    Layout {
        width: x + MARGIN,
        height: end + MARGIN,
        nodes,
        edges: paths,
        groups: Vec::new(),
        lifeline_end: Some(end),
    }
}

/// The folded inline form of a sequence: each [`FoldLane`] is one column (its header lists the
/// group's members), messages between different lanes are kept, and a run of ≥2 consecutive
/// messages inside one lane — or any single message whose label carries a number — folds into a
/// bundle row (`EdgePath.bundle`). Numbers are hoisted into the bundle label; single numberless
/// messages drop out. Lossy on structure, lossless on numbers.
fn sequence_layout_folded(d: &Diagram, lanes: &[FoldLane]) -> Layout {
    // Which lane each participant sits in (every node has a group when we fold).
    let mut lane_of: HashMap<&str, usize> = HashMap::new();
    for (li, l) in lanes.iter().enumerate() {
        for &i in &l.members {
            lane_of.insert(d.nodes[i].id.as_str(), li);
        }
    }
    let lane_of_edge: Vec<Option<usize>> = d
        .edges
        .iter()
        .map(|e| {
            let (a, b) = (
                lane_of.get(e.from.as_str()).copied(),
                lane_of.get(e.to.as_str()).copied(),
            );
            match (a, b) {
                (Some(a), Some(b)) => Some(a.min(b)),
                _ => None,
            }
        })
        .collect();
    let lane_group: Vec<usize> = lanes
        .iter()
        .map(|l| {
            d.nodes
                .get(*l.members.first().unwrap_or(&0))
                .and_then(|n| n.group.as_deref())
                .and_then(|g| d.groups.iter().position(|x| x.id == g))
                .unwrap_or(0)
        })
        .collect();

    // Columns: each lane is as wide as its header label (with a member count) and the widest
    // participant label inside it; message labels between two neighbors add room.
    let mut need = vec![0f32; lanes.len().saturating_sub(1)];
    for e in &d.edges {
        let (Some(a), Some(b)) = (
            lane_of.get(e.from.as_str()).copied(),
            lane_of.get(e.to.as_str()).copied(),
        ) else {
            continue;
        };
        if b != a + 1 {
            continue;
        }
        let w = e
            .label
            .as_ref()
            .map(|l| l.chars().count() as f32 * CHAR_W + 32.0)
            .unwrap_or(60.0);
        need[a] = need[a].max(w);
    }
    let sizes: Vec<(f32, f32)> = lanes
        .iter()
        .map(|l| {
            let header = if l.members.len() > 1 {
                format!("{} · {}", l.label, l.members.len())
            } else {
                l.label.clone()
            };
            let widest = l
                .members
                .iter()
                .filter_map(|&i| d.nodes.get(i))
                .map(|n| n.label.chars().count())
                .max()
                .unwrap_or(0) as f32;
            let (w, h) = measure(&Node {
                label: clip(&header, MAX_LABEL),
                ..Default::default()
            });
            (w.max(widest * CHAR_W + 24.0), h)
        })
        .collect();
    let mut cx = vec![0f32; lanes.len()];
    let mut x = MARGIN;
    for i in 0..lanes.len() {
        if i == 0 {
            cx[i] = x + sizes[i].0 / 2.0;
        } else {
            let min = cx[i - 1] + sizes[i - 1].0 / 2.0 + 36.0 + sizes[i].0 / 2.0;
            cx[i] = min.max(cx[i - 1] + need[i - 1]).max(cx[i - 1] + 110.0);
        }
        x = cx[i] + sizes[i].0 / 2.0;
    }
    let header_h = sizes.iter().map(|s| s.1).fold(0f32, f32::max);
    // Lane headers are NodeBoxes keyed by the group's id, so the client resolves the label (the
    // group's members and count) and the hover detail through `diagram.groups` / `diagram.nodes`.
    let nodes: Vec<NodeBox> = lanes
        .iter()
        .enumerate()
        .map(|(i, _l)| NodeBox {
            id: d.groups[lane_group[i]].id.clone(),
            x: cx[i] - sizes[i].0 / 2.0,
            y: MARGIN,
            w: sizes[i].0,
            h: header_h,
            rank: i,
        })
        .collect();

    // Rows: messages in time order. A run of consecutive same-lane messages folds into one
    // bundle; between-lane messages draw as themselves.
    let mut paths: Vec<EdgePath> = Vec::new();
    let mut y = MARGIN + header_h + 34.0;
    let mut run: Vec<(usize, &Edge)> = Vec::new();
    let mut run_lane: Option<usize> = None;
    for (k, e) in d.edges.iter().enumerate() {
        let (Some(a), Some(b)) = (
            lane_of.get(e.from.as_str()).copied(),
            lane_of.get(e.to.as_str()).copied(),
        ) else {
            continue;
        };
        if a == b {
            // A self-message (or within-lane hop): part of the lane's current run.
            if run_lane == Some(a) {
                run.push((k, e));
                continue;
            }
            y = flush_bundle(&mut run, &mut run_lane, y, &mut paths, &cx);
            run_lane = Some(a);
            run.push((k, e));
        } else {
            // Between lanes: kept as its own arrow, breaking any run.
            y = flush_bundle(&mut run, &mut run_lane, y, &mut paths, &cx);
            let x0 = cx[a.min(b)];
            let x1 = cx[a.max(b)];
            paths.push(EdgePath {
                edge: k,
                points: vec![[x0, y], [x1, y]],
                label_at: e.label.as_ref().map(|_| [(x0 + x1) / 2.0, y - 10.0]),
                bundle: None,
            });
            y += 38.0;
        }
    }
    y = flush_bundle(&mut run, &mut run_lane, y, &mut paths, &cx);
    let end = y + 4.0;
    Layout {
        width: x + MARGIN,
        height: end + MARGIN,
        nodes,
        edges: paths,
        groups: Vec::new(),
        lifeline_end: Some(end),
    }
}

/// Draws a finished run of same-lane messages as one row and returns the next row's y. A single
/// numberless message drops out; a single numbered one or a run of ≥2 becomes a bundle row with
/// the numbers hoisted into its label.
fn flush_bundle(
    run: &mut Vec<(usize, &Edge)>,
    run_lane: &mut Option<usize>,
    y: f32,
    paths: &mut Vec<EdgePath>,
    cx: &[f32],
) -> f32 {
    let Some(lane) = *run_lane else { return y };
    run_lane.take();
    let numbered = run
        .iter()
        .any(|(_, e)| e.label.as_deref().is_some_and(carries_number));
    let label = run
        .iter()
        .filter_map(|(_, e)| e.label.as_deref().and_then(hoist_numbers))
        .collect::<Vec<_>>()
        .join(" · ");
    if run.len() == 1 && !numbered {
        // Says nothing measurable: dropped (the footer counts it).
        run.clear();
        return y;
    }
    let bundle = Bundle {
        lane,
        count: run.len(),
        label: if label.is_empty() {
            format!("×{}", run.len())
        } else {
            label
        },
    };
    let w = (bundle.label.chars().count() as f32 * CHAR_W + 60.0).max(96.0);
    paths.push(EdgePath {
        edge: 0,
        points: vec![[cx[lane] - w / 2.0, y + 9.0], [cx[lane] + w / 2.0, y + 9.0]],
        label_at: Some([cx[lane], y]),
        bundle: Some(bundle),
    });
    run.clear();
    y + 44.0
}

/// The measured values in a label ("batch 40 ms, 8 tok/s" → "40 ms · 8 tok/s", "1000+ tok/s"
/// → "1000+ tok/s"), or None when it carries none.
fn hoist_numbers(label: &str) -> Option<String> {
    use std::sync::LazyLock;
    static NUMBERS: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"\d[\d.,]*\s?(?:ms|s|µs|%|x|×|tok/s|GB|k)?\+?(?:\s?(?:ms|s|µs|%|x|×|tok/s|GB|k))?\b").unwrap()
    });
    let found: Vec<String> = NUMBERS
        .find_iter(label)
        .map(|m| m.as_str().trim().to_string())
        .filter(|m| m.chars().any(|c| c.is_ascii_digit()))
        .collect();
    (!found.is_empty()).then(|| found.join(" · "))
}

// MARK: - Mermaid

impl Diagram {
    pub fn to_mermaid(&self) -> String {
        let q = |s: &str| s.replace('"', "'");
        let mut out = String::new();
        match self.kind {
            Kind::Sequence => {
                out.push_str("sequenceDiagram\n");
                for n in &self.nodes {
                    let kw = if n.shape == Shape::Actor {
                        "actor"
                    } else {
                        "participant"
                    };
                    out.push_str(&format!("    {kw} {} as {}\n", n.id, q(&n.label)));
                }
                for e in &self.edges {
                    let arrow = if e.style == EdgeStyle::Dashed {
                        "-->>"
                    } else {
                        "->>"
                    };
                    out.push_str(&format!(
                        "    {}{arrow}{}: {}\n",
                        e.from,
                        e.to,
                        q(e.label.as_deref().unwrap_or(""))
                    ));
                }
            }
            Kind::Flow => {
                let dir = if self.direction == Direction::Right {
                    "LR"
                } else {
                    "TD"
                };
                out.push_str(&format!("flowchart {dir}\n"));
                let node = |n: &Node| {
                    let l = q(&n.label);
                    match n.shape {
                        Shape::Box => format!("{}[\"{l}\"]", n.id),
                        Shape::Rounded => format!("{}(\"{l}\")", n.id),
                        Shape::Store => format!("{}[(\"{l}\")]", n.id),
                        Shape::Actor => format!("{}([\"{l}\"])", n.id),
                        Shape::Decision => format!("{}{{\"{l}\"}}", n.id),
                        Shape::External => format!("{}[/\"{l}\"/]", n.id),
                    }
                };
                for g in &self.groups {
                    out.push_str(&format!("    subgraph {} [\"{}\"]\n", g.id, q(&g.label)));
                    for n in self
                        .nodes
                        .iter()
                        .filter(|n| n.group.as_deref() == Some(&g.id))
                    {
                        out.push_str(&format!("        {}\n", node(n)));
                    }
                    out.push_str("    end\n");
                }
                for n in self.nodes.iter().filter(|n| n.group.is_none()) {
                    out.push_str(&format!("    {}\n", node(n)));
                }
                for e in &self.edges {
                    let arrow = match e.style {
                        EdgeStyle::Solid => "-->",
                        EdgeStyle::Dashed => "-.->",
                        EdgeStyle::Thick => "==>",
                    };
                    match &e.label {
                        Some(l) => out.push_str(&format!(
                            "    {} {arrow}|\"{}\"| {}\n",
                            e.from,
                            q(l),
                            e.to
                        )),
                        None => out.push_str(&format!("    {} {arrow} {}\n", e.from, e.to)),
                    }
                }
            }
        }
        out
    }

    /// Parse the common subset of Mermaid: `flowchart`/`graph` (node shapes, labeled and
    /// styled edges, chains, subgraphs) and `sequenceDiagram` (participants, messages).
    pub fn from_mermaid(src: &str) -> Option<Diagram> {
        let mut lines = src
            .lines()
            .map(|l| l.split("%%").next().unwrap_or("").trim())
            .filter(|l| !l.is_empty());
        let head = lines.next()?;
        let mut d = Diagram::default();
        if head.starts_with("sequenceDiagram") {
            d.kind = Kind::Sequence;
            let mut seen = HashSet::new();
            for l in lines {
                if let Some(rest) = l
                    .strip_prefix("participant ")
                    .or_else(|| l.strip_prefix("actor "))
                {
                    let (id, label) = match rest.split_once(" as ") {
                        Some((a, b)) => (a.trim(), b.trim()),
                        None => (rest.trim(), rest.trim()),
                    };
                    if seen.insert(id.to_string()) {
                        let shape = if l.starts_with("actor") {
                            Shape::Actor
                        } else {
                            Shape::Box
                        };
                        d.nodes.push(Node {
                            id: id.into(),
                            label: label.into(),
                            shape,
                            ..Default::default()
                        });
                    }
                    continue;
                }
                let Some((lhs, msg)) = l.split_once(':') else {
                    continue;
                };
                let arrows = ["-->>", "->>", "-->", "->", "--)", "-)", "--x", "-x"];
                let Some((arrow, pos)) = arrows.iter().find_map(|a| lhs.find(a).map(|p| (*a, p)))
                else {
                    continue;
                };
                let from = lhs[..pos].trim().trim_end_matches(['+', '-']).to_string();
                let to = lhs[pos + arrow.len()..]
                    .trim()
                    .trim_start_matches(['+', '-'])
                    .to_string();
                if from.is_empty() || to.is_empty() {
                    continue;
                }
                for id in [&from, &to] {
                    if seen.insert(id.clone()) {
                        d.nodes.push(Node {
                            id: id.clone(),
                            label: id.clone(),
                            ..Default::default()
                        });
                    }
                }
                let style = if arrow.starts_with("--") {
                    EdgeStyle::Dashed
                } else {
                    EdgeStyle::Solid
                };
                let label = msg.trim();
                d.edges.push(Edge {
                    from,
                    to,
                    label: (!label.is_empty()).then(|| label.into()),
                    style,
                });
            }
            return (!d.nodes.is_empty()).then_some(d);
        }
        if !(head.starts_with("flowchart") || head.starts_with("graph")) {
            return None;
        }
        if head.contains("LR") || head.contains("RL") {
            d.direction = Direction::Right;
        }
        let mut known: HashMap<String, usize> = HashMap::new();
        let mut group: Option<String> = None;
        for l in lines {
            if let Some(rest) = l.strip_prefix("subgraph") {
                let rest = rest.trim();
                let (id, label) = match rest.find(['[', '"']) {
                    Some(i) => (
                        rest[..i].trim().to_string(),
                        unquote(rest[i..].trim_matches(['[', ']'])),
                    ),
                    None => (slug(rest).unwrap_or_else(|| rest.into()), rest.to_string()),
                };
                let id = if id.is_empty() {
                    slug(&label).unwrap_or_else(|| "group".into())
                } else {
                    id
                };
                d.groups.push(Group {
                    id: id.clone(),
                    label,
                });
                group = Some(id);
                continue;
            }
            if l == "end" {
                group = None;
                continue;
            }
            if [
                "classDef",
                "class ",
                "style ",
                "linkStyle",
                "click ",
                "direction ",
            ]
            .iter()
            .any(|k| l.starts_with(k))
            {
                continue;
            }
            // A chain of node references separated by arrows.
            let mut rest = l;
            let mut prev: Option<String> = None;
            let mut pending: Option<(EdgeStyle, Option<String>)> = None;
            while !rest.is_empty() {
                rest = rest.trim_start();
                let Some((node, after)) = parse_node(rest) else {
                    break;
                };
                let idx = *known.entry(node.id.clone()).or_insert_with(|| {
                    d.nodes.push(Node {
                        id: node.id.clone(),
                        label: node.id.clone(),
                        ..Default::default()
                    });
                    d.nodes.len() - 1
                });
                if !node.label.is_empty() {
                    d.nodes[idx].label = node.label.clone();
                    d.nodes[idx].shape = node.shape;
                }
                if let Some(g) = &group {
                    d.nodes[idx].group.get_or_insert_with(|| g.clone());
                }
                if let (Some(p), Some((style, label))) = (prev.take(), pending.take()) {
                    d.edges.push(Edge {
                        from: p,
                        to: node.id.clone(),
                        label,
                        style,
                    });
                }
                prev = Some(node.id);
                rest = after.trim_start();
                match parse_arrow(rest) {
                    Some((style, label, after)) => {
                        pending = Some((style, label));
                        rest = after;
                    }
                    None => break,
                }
            }
        }
        (!d.nodes.is_empty()).then_some(d)
    }
}

fn unquote(s: &str) -> String {
    s.trim().trim_matches('"').trim().to_string()
}

/// `id`, `id[label]`, `id(label)`, `id{label}`, `id[(label)]`, `id([label])`, `id((label))`,
/// `id[/label/]`. Returns the node and the rest of the line.
fn parse_node(s: &str) -> Option<(Node, &str)> {
    let end = s
        .find(|c: char| !(c.is_alphanumeric() || c == '_' || c == '-' || c == '.'))
        .unwrap_or(s.len());
    // `-` inside ids is fine, but not the start of an arrow.
    let mut end = end;
    if let Some(p) = s[..end].find("--").or_else(|| s[..end].find("-.")) {
        end = p;
    }
    let id = s[..end].trim_end_matches('-');
    if id.is_empty() {
        return None;
    }
    let rest = &s[id.len()..];
    let shapes: [(&str, &str, Shape); 8] = [
        ("[(", ")]", Shape::Store),
        ("([", "])", Shape::Actor),
        ("((", "))", Shape::Rounded),
        ("[/", "/]", Shape::External),
        ("[", "]", Shape::Box),
        ("(", ")", Shape::Rounded),
        ("{", "}", Shape::Decision),
        (">", "]", Shape::Box),
    ];
    for (open, close, shape) in shapes {
        if let Some(inner) = rest.strip_prefix(open)
            && let Some(stop) = inner.find(close)
        {
            let label = unquote(&inner[..stop]);
            return Some((
                Node {
                    id: id.into(),
                    label,
                    shape,
                    ..Default::default()
                },
                &inner[stop + close.len()..],
            ));
        }
    }
    Some((
        Node {
            id: id.into(),
            ..Default::default()
        },
        rest,
    ))
}

/// An arrow with an optional label: `-->`, `---`, `-.->`, `==>`, `-->|label|`, `-- label -->`.
fn parse_arrow(s: &str) -> Option<(EdgeStyle, Option<String>, &str)> {
    let arrows: [(&str, EdgeStyle); 6] = [
        ("-.->", EdgeStyle::Dashed),
        ("-.-", EdgeStyle::Dashed),
        ("==>", EdgeStyle::Thick),
        ("-->", EdgeStyle::Solid),
        ("---", EdgeStyle::Solid),
        ("->", EdgeStyle::Solid),
    ];
    // `-- label -->` / `== label ==>` / `-. label .->`
    for (open, close, style) in [
        ("-- ", "-->", EdgeStyle::Solid),
        ("== ", "==>", EdgeStyle::Thick),
        ("-. ", ".->", EdgeStyle::Dashed),
    ] {
        if let Some(inner) = s.strip_prefix(open)
            && let Some(stop) = inner.find(close)
        {
            return Some((
                style,
                Some(unquote(&inner[..stop])),
                &inner[stop + close.len()..],
            ));
        }
    }
    for (a, style) in arrows {
        if let Some(rest) = s.strip_prefix(a) {
            let rest = rest.trim_start();
            if let Some(inner) = rest.strip_prefix('|')
                && let Some(stop) = inner.find('|')
            {
                return Some((style, Some(unquote(&inner[..stop])), &inner[stop + 1..]));
            }
            return Some((style, None, rest));
        }
    }
    None
}

// MARK: - Terminal

impl Diagram {
    /// Box-drawing rendering for the terminal. Flows always draw top-down here.
    pub fn to_ascii(&self) -> String {
        match self.kind {
            Kind::Flow => {
                let mut d = self.clone();
                d.direction = Direction::Down;
                ascii_flow(&d)
            }
            Kind::Sequence => ascii_sequence(self),
        }
    }
}

struct Grid {
    cells: Vec<Vec<char>>,
}

impl Grid {
    fn new(w: usize, h: usize) -> Self {
        Self {
            cells: vec![vec![' '; w]; h],
        }
    }
    fn get(&self, x: usize, y: usize) -> char {
        self.cells
            .get(y)
            .and_then(|r| r.get(x))
            .copied()
            .unwrap_or(' ')
    }
    fn put(&mut self, x: usize, y: usize, c: char) {
        if let Some(cell) = self.cells.get_mut(y).and_then(|r| r.get_mut(x)) {
            *cell = c;
        }
    }
    /// Lines merge where they meet: each cell keeps the union of the directions drawn
    /// through it (up, down, left, right) and shows the matching box-drawing character.
    fn line(&mut self, x: usize, y: usize, c: char) {
        let cur = self.get(x, y);
        if "▼▶◀▲".contains(cur) {
            return;
        }
        match (dirs(cur), dirs(c)) {
            (Some(a), Some(b)) => self.put(x, y, if a == 0 { c } else { junction(a | b, cur, c) }),
            _ => self.put(x, y, c),
        }
    }
    fn text(&mut self, x: usize, y: usize, s: &str) {
        for (i, c) in s.chars().enumerate() {
            self.put(x + i, y, c);
        }
    }
    fn render(self) -> String {
        self.cells
            .into_iter()
            .map(|r| r.into_iter().collect::<String>().trim_end().to_string())
            .collect::<Vec<_>>()
            .join("\n")
            .trim_end()
            .to_string()
    }
}

const UP: u8 = 1;
const DOWN: u8 = 2;
const LEFT: u8 = 4;
const RIGHT: u8 = 8;

/// Which directions a line character connects; None for anything that isn't a line.
fn dirs(c: char) -> Option<u8> {
    Some(match c {
        ' ' => 0,
        '│' | '┆' | '┃' => UP | DOWN,
        '─' | '┄' | '━' => LEFT | RIGHT,
        '┌' => DOWN | RIGHT,
        '┐' => DOWN | LEFT,
        '└' => UP | RIGHT,
        '┘' => UP | LEFT,
        '├' => UP | DOWN | RIGHT,
        '┤' => UP | DOWN | LEFT,
        '┬' => DOWN | LEFT | RIGHT,
        '┴' => UP | LEFT | RIGHT,
        '┼' => UP | DOWN | LEFT | RIGHT,
        _ => return None,
    })
}

fn junction(d: u8, cur: char, new: char) -> char {
    match d {
        // A shared straight stretch keeps whatever was drawn first (solid edges draw first).
        x if x == UP | DOWN => {
            if "│┆┃".contains(cur) {
                cur
            } else if "│┆┃".contains(new) {
                new
            } else {
                '│'
            }
        }
        x if x == LEFT | RIGHT => {
            if "─┄━".contains(cur) {
                cur
            } else if "─┄━".contains(new) {
                new
            } else {
                '─'
            }
        }
        x if x == DOWN | RIGHT => '┌',
        x if x == DOWN | LEFT => '┐',
        x if x == UP | RIGHT => '└',
        x if x == UP | LEFT => '┘',
        x if x == UP | DOWN | RIGHT => '├',
        x if x == UP | DOWN | LEFT => '┤',
        x if x == DOWN | LEFT | RIGHT => '┬',
        x if x == UP | LEFT | RIGHT => '┴',
        _ => '┼',
    }
}

fn ascii_flow(d: &Diagram) -> String {
    let layout = d.layout();
    // Map points to cells: 7pt per column; rows come from layer order, since boxes need a
    // fixed number of rows regardless of their point height.
    let col = |x: f32| (x / 7.0).round().max(0.0) as usize;
    let mut ranks: Vec<usize> = layout.nodes.iter().map(|b| b.rank).collect();
    ranks.sort();
    ranks.dedup();
    let lines_of = |id: &str| {
        d.nodes
            .iter()
            .find(|n| n.id == id)
            .map(|n| wrap(&n.label))
            .unwrap_or_default()
    };
    let mut rank_row: HashMap<usize, (usize, usize)> = HashMap::new(); // rank -> (top row, height)
    let mut row = 0usize;
    for &r in &ranks {
        let h = layout
            .nodes
            .iter()
            .filter(|b| b.rank == r)
            .map(|b| lines_of(&b.id).len() + 2)
            .max()
            .unwrap_or(3);
        rank_row.insert(r, (row, h));
        row += h + 3;
    }
    let boxes: Vec<(usize, usize, usize, usize)> = layout
        .nodes
        .iter()
        .map(|b| {
            let lines = lines_of(&b.id);
            let w = lines.iter().map(|l| l.chars().count()).max().unwrap_or(0) + 4;
            let (top, _) = rank_row[&b.rank];
            let cx = col(b.x + b.w / 2.0);
            (cx.saturating_sub(w / 2), top, w, lines.len() + 2)
        })
        .collect();
    let width = boxes.iter().map(|b| b.0 + b.2).max().unwrap_or(0) + 30;
    let mut g = Grid::new(width, row.max(1));
    // Edges first, under the boxes: down from the source, across at the midpoint row, down
    // into the target.
    // Solid edges first, so shared stretches read as solid.
    let mut order: Vec<&EdgePath> = layout.edges.iter().collect();
    order.sort_by_key(|p| d.edges[p.edge].style == EdgeStyle::Dashed);
    for p in order {
        let e = &d.edges[p.edge];
        let (Some(a), Some(b)) = (
            layout.nodes.iter().position(|n| n.id == e.from),
            layout.nodes.iter().position(|n| n.id == e.to),
        ) else {
            continue;
        };
        if a == b {
            continue;
        }
        let (ax, ay, aw, ah) = boxes[a];
        let (bx, by, bw, bh) = boxes[b];
        let (sx, sy) = (ax + aw / 2, ay + ah);
        let (tx, ty) = (bx + bw / 2, by);
        let (vch, hch) = match e.style {
            EdgeStyle::Dashed => ('┆', '┄'),
            EdgeStyle::Thick => ('┃', '━'),
            EdgeStyle::Solid => ('│', '─'),
        };
        if ty > sy {
            let mid = sy + (ty - sy) / 2;
            if sx == tx {
                for y in sy..ty.saturating_sub(1) {
                    g.line(sx, y, vch);
                }
            } else {
                for y in sy..mid {
                    g.line(sx, y, vch);
                }
                let (lo, hi) = (sx.min(tx), sx.max(tx));
                for x in lo + 1..hi {
                    g.line(x, mid, hch);
                }
                g.line(sx, mid, if tx > sx { '└' } else { '┘' });
                g.line(tx, mid, if tx > sx { '┐' } else { '┌' });
                for y in mid + 1..ty.saturating_sub(1) {
                    g.line(tx, y, vch);
                }
            }
            g.put(tx, ty.saturating_sub(1), '▼');
            if let Some(l) = &e.label {
                g.text(
                    tx + 2,
                    ty.saturating_sub(2).max(mid + 1).min(ty.saturating_sub(1)),
                    l,
                );
            }
        } else {
            // Back edge: up the right side.
            let x = ax.max(bx) + aw.max(bw) + 2;
            let (top, bottom) = (by + bh / 2, ay + ah / 2);
            for y in top + 1..bottom {
                g.line(x, y, vch);
            }
            for xx in ax + aw..x {
                g.line(xx, bottom, hch);
            }
            for xx in bx + bw..x {
                g.line(xx, top, hch);
            }
            g.line(x, bottom, '┘');
            g.line(x, top, '┐');
            g.put(bx + bw, top, '◀');
            if let Some(l) = &e.label {
                g.text(x + 2, (top + bottom) / 2, l);
            }
        }
    }
    for (i, &(x, y, w, h)) in boxes.iter().enumerate() {
        let node = d.nodes.iter().find(|n| n.id == layout.nodes[i].id).unwrap();
        let (tl, tr, bl, br) = match node.shape {
            Shape::Rounded | Shape::Actor => ('╭', '╮', '╰', '╯'),
            Shape::Decision => ('◇', '◇', '◇', '◇'),
            _ => ('┌', '┐', '└', '┘'),
        };
        let hz = if node.shape == Shape::External {
            '╌'
        } else {
            '─'
        };
        let vt = if node.shape == Shape::External {
            '╎'
        } else {
            '│'
        };
        for xx in x..x + w {
            g.put(xx, y, hz);
            g.put(xx, y + h - 1, hz);
        }
        for yy in y..y + h {
            g.put(x, yy, vt);
            g.put(x + w - 1, yy, vt);
        }
        g.put(x, y, tl);
        g.put(x + w - 1, y, tr);
        g.put(x, y + h - 1, bl);
        g.put(x + w - 1, y + h - 1, br);
        if node.shape == Shape::Store {
            g.put(x, y, '╭');
            g.put(x + w - 1, y, '╮');
            for xx in x + 1..x + w - 1 {
                g.put(
                    xx,
                    y + 1,
                    if y + 1 == y + h - 1 {
                        '─'
                    } else {
                        g.get(xx, y + 1)
                    },
                );
            }
        }
        for xx in x + 1..x + w - 1 {
            for yy in y + 1..y + h - 1 {
                g.put(xx, yy, ' ');
            }
        }
        for (k, l) in wrap(&node.label).iter().enumerate() {
            let lx = x + (w - l.chars().count()) / 2;
            g.text(lx, y + 1 + k, l);
        }
    }
    let mut out = String::new();
    if !d.title.is_empty() {
        out.push_str(&d.title);
        out.push('\n');
    }
    out.push_str(&g.render());
    out
}

fn ascii_sequence(d: &Diagram) -> String {
    let n = d.nodes.len();
    if n == 0 {
        return d.title.clone();
    }
    let index: HashMap<&str, usize> = d
        .nodes
        .iter()
        .enumerate()
        .map(|(i, n)| (n.id.as_str(), i))
        .collect();
    let widths: Vec<usize> = d
        .nodes
        .iter()
        .map(|n| n.label.chars().count() + 4)
        .collect();
    let mut cx = vec![0usize; n];
    for i in 0..n {
        cx[i] = if i == 0 {
            widths[0] / 2
        } else {
            let label_need = d
                .edges
                .iter()
                .filter(|e| {
                    let (a, b) = (index.get(e.from.as_str()), index.get(e.to.as_str()));
                    matches!((a, b), (Some(&a), Some(&b)) if a.min(b) == i - 1 && a.max(b) == i)
                })
                .map(|e| e.label.as_ref().map(|l| l.chars().count()).unwrap_or(0) + 6)
                .max()
                .unwrap_or(0);
            cx[i - 1]
                + (widths[i - 1] / 2 + widths[i] / 2 + 4)
                    .max(label_need)
                    .max(14)
        };
    }
    let width = cx[n - 1] + widths[n - 1] + 20;
    let rows = 3 + d.edges.len() * 2 + 1;
    let mut g = Grid::new(width, rows);
    for i in 0..n {
        let x = cx[i] - widths[i] / 2;
        g.text(x, 0, &format!("┌{}┐", "─".repeat(widths[i] - 2)));
        g.text(x, 1, &format!("│ {} │", d.nodes[i].label));
        g.text(x, 2, &format!("└{}┘", "─".repeat(widths[i] - 2)));
        g.put(cx[i], 2, '┬');
        for y in 3..rows {
            g.put(cx[i], y, '│');
        }
    }
    let mut y = 3;
    for e in &d.edges {
        let (Some(&a), Some(&b)) = (index.get(e.from.as_str()), index.get(e.to.as_str())) else {
            continue;
        };
        let label = e.label.clone().unwrap_or_default();
        let dash = if e.style == EdgeStyle::Dashed {
            '┄'
        } else {
            '─'
        };
        if a == b {
            g.text(cx[a] + 1, y + 1, &format!("{dash}{dash}┐ {label}"));
            g.text(cx[a] + 1, y + 2, &format!("◀{dash}┘"));
            y += 2;
            continue;
        }
        let (lo, hi) = (cx[a].min(cx[b]), cx[a].max(cx[b]));
        for x in lo + 1..hi {
            g.put(x, y + 1, dash);
        }
        if cx[b] > cx[a] {
            g.put(hi - 1, y + 1, '▶')
        } else {
            g.put(lo + 1, y + 1, '◀')
        }
        let lx = lo + 2 + (hi - lo).saturating_sub(label.chars().count() + 3) / 2;
        g.text(lx, y, &label);
        y += 2;
    }
    let mut out = String::new();
    if !d.title.is_empty() {
        out.push_str(&d.title);
        out.push('\n');
    }
    out.push_str(&g.render());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flow() -> Diagram {
        serde_json::from_value(serde_json::json!({
            "kind": "flow",
            "title": "Request path",
            "nodes": [
                {"id": "client", "label": "Mac app", "shape": "actor"},
                {"id": "engine", "label": "frog-engine", "group": "core"},
                {"id": "store", "label": "Session log", "shape": "store", "group": "core"},
                {"id": "model", "label": "Model provider", "shape": "external"}
            ],
            "edges": [
                {"from": "client", "to": "engine", "label": "ops"},
                {"from": "engine", "to": "model", "label": "requests"},
                {"from": "engine", "to": "store", "style": "dashed"},
                {"from": "model", "to": "engine", "label": "stream"}
            ]
        }))
        .unwrap()
    }

    fn overlaps(a: &NodeBox, b: &NodeBox) -> bool {
        a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
    }

    #[test]
    fn flow_layout_layers_without_overlap_and_routes_every_edge() {
        let mut d = flow();
        let warnings = d.finish(Path::new("/"));
        assert!(warnings.is_empty(), "{warnings:?}");
        let l = d.layout.as_ref().unwrap();
        assert_eq!(l.nodes.len(), 4);
        assert_eq!(l.edges.len(), 4);
        for (i, a) in l.nodes.iter().enumerate() {
            for b in &l.nodes[i + 1..] {
                assert!(!overlaps(a, b), "{} overlaps {}", a.id, b.id);
            }
            assert!(a.x >= 0.0 && a.y >= 0.0 && a.x + a.w <= l.width && a.y + a.h <= l.height);
        }
        let rank = |id: &str| l.nodes.iter().find(|n| n.id == id).unwrap().rank;
        assert!(rank("client") < rank("engine") && rank("engine") < rank("store"));
        // The cycle (engine -> model -> engine) is broken, but both edges are drawn in their
        // real direction.
        let model_back = &l.edges[3];
        let m = l.nodes.iter().find(|n| n.id == "model").unwrap();
        let first = model_back.points[0];
        assert!(
            first[1] >= m.y - 1.0 && first[1] <= m.y + m.h + 1.0,
            "starts at the model"
        );
        assert_eq!(l.groups.len(), 1);
        let g = &l.groups[0];
        for id in ["engine", "store"] {
            let n = l.nodes.iter().find(|n| n.id == id).unwrap();
            assert!(n.x >= g.x && n.x + n.w <= g.x + g.w && n.y >= g.y && n.y + n.h <= g.y + g.h);
        }
    }

    #[test]
    fn prepare_creates_missing_nodes_and_drops_missing_files() {
        let mut d: Diagram = serde_json::from_value(serde_json::json!({
            "nodes": [{"label": "API Server", "file": "src/definitely_missing.rs"}],
            "edges": [{"from": "api_server", "to": "db"}]
        }))
        .unwrap();
        let warnings = d.prepare(Path::new("/"));
        assert_eq!(d.nodes[0].id, "api_server");
        assert!(d.nodes.iter().any(|n| n.id == "db"));
        assert!(d.nodes[0].file.is_none());
        assert!(warnings.iter().any(|w| w.contains("doesn't exist")));
    }

    #[test]
    fn mermaid_round_trips_flow_and_sequence() {
        let src = "flowchart LR\n  subgraph core [Core]\n    A[Engine] -->|events| B[(Log)]\n  end\n  C([User]) --> A\n  A -.-> D[/API/]\n  A == hot ==> B\n";
        let d = Diagram::from_mermaid(src).unwrap();
        assert_eq!(d.direction, Direction::Right);
        assert_eq!(d.nodes.len(), 4);
        assert_eq!(d.edges.len(), 4);
        let b = d.nodes.iter().find(|n| n.id == "B").unwrap();
        assert_eq!(
            (b.shape, b.label.as_str(), b.group.as_deref()),
            (Shape::Store, "Log", Some("core"))
        );
        assert_eq!(d.edges[0].label.as_deref(), Some("events"));
        assert_eq!(d.edges[2].style, EdgeStyle::Dashed);
        assert_eq!(
            (d.edges[3].style, d.edges[3].label.as_deref()),
            (EdgeStyle::Thick, Some("hot"))
        );
        let again = Diagram::from_mermaid(&d.to_mermaid()).unwrap();
        assert_eq!(again.nodes.len(), d.nodes.len());
        assert_eq!(again.edges.len(), d.edges.len());

        let seq = Diagram::from_mermaid(
            "sequenceDiagram\n participant U as User\n U->>S: request\n S-->>U: response\n",
        )
        .unwrap();
        assert_eq!(seq.kind, Kind::Sequence);
        assert_eq!(seq.nodes.len(), 2);
        assert_eq!(seq.edges[1].style, EdgeStyle::Dashed);
    }

    #[test]
    fn sequence_layout_orders_messages_down_the_page() {
        let mut d = Diagram::from_mermaid(
            "sequenceDiagram\n A->>B: hello\n B->>C: forward it\n C-->>A: done\n A->>A: think\n",
        )
        .unwrap();
        d.finish(Path::new("/"));
        let l = d.layout.unwrap();
        let ys: Vec<f32> = l.edges.iter().map(|e| e.points[0][1]).collect();
        assert!(ys.windows(2).all(|w| w[1] > w[0]));
        assert!(l.lifeline_end.unwrap() > *ys.last().unwrap());
        let xs: Vec<f32> = l.nodes.iter().map(|n| n.x).collect();
        assert!(xs.windows(2).all(|w| w[1] > w[0]));
    }

    #[test]
    fn ascii_draws_boxes_and_arrows() {
        let mut d = flow();
        d.finish(Path::new("/"));
        let art = d.to_ascii();
        for label in ["Mac app", "frog-engine", "Session log", "Model provider"] {
            assert!(art.contains(label), "{label} missing:\n{art}");
        }
        assert!(art.contains('▼'));
        let seq = Diagram::from_mermaid("sequenceDiagram\n A->>B: hi\n B-->>A: yo\n").unwrap();
        let art = seq.to_ascii();
        assert!(
            art.contains("hi") && art.contains('▶') && art.contains('◀'),
            "{art}"
        );
    }

    #[test]
    fn non_members_stay_outside_group_frames_and_parallel_edges_fan_out() {
        let src = "flowchart TD\n subgraph e [Engine]\n loop[Agent loop] --> tools[Tools]\n loop -.-> log[(Log)]\n end\n app[App] --> loop\n loop ==>|chat| model[/Model/]\n model -->|stream| loop\n";
        let mut d = Diagram::from_mermaid(src).unwrap();
        d.finish(Path::new("/"));
        let l = d.layout.as_ref().unwrap();
        let frame = &l.groups[0];
        for b in &l.nodes {
            let member = d.node_group(&b.id) == Some("e");
            let inside = b.x < frame.x + frame.w
                && frame.x < b.x + b.w
                && b.y < frame.y + frame.h
                && frame.y < b.y + b.h;
            assert!(member || !inside, "{} overlaps the group frame", b.id);
        }
        let chat = l
            .edges
            .iter()
            .find(|p| d.edges[p.edge].label.as_deref() == Some("chat"))
            .unwrap();
        let stream = l
            .edges
            .iter()
            .find(|p| d.edges[p.edge].label.as_deref() == Some("stream"))
            .unwrap();
        assert_ne!(chat.label_at, stream.label_at);
    }

    #[test]
    fn big_layered_graph_has_no_overlaps() {
        let mut nodes = Vec::new();
        let mut edges = Vec::new();
        for i in 0..24 {
            nodes.push(serde_json::json!({"id": format!("n{i}"), "label": format!("Component number {i}")}));
            if i > 0 {
                edges.push(
                    serde_json::json!({"from": format!("n{}", i / 3), "to": format!("n{i}")}),
                );
            }
            if i > 5 {
                edges.push(
                    serde_json::json!({"from": format!("n{}", i - 5), "to": format!("n{i}")}),
                );
            }
        }
        let mut d: Diagram =
            serde_json::from_value(serde_json::json!({"nodes": nodes, "edges": edges})).unwrap();
        d.finish(Path::new("/"));
        let l = d.layout.unwrap();
        for (i, a) in l.nodes.iter().enumerate() {
            for b in &l.nodes[i + 1..] {
                assert!(!overlaps(a, b), "{} overlaps {}", a.id, b.id);
            }
        }
    }
}

#[cfg(test)]
mod inline_tests {
    use super::*;

    /// The screenshot's case 2, rebuilt: 13 participants, numbered messages. Used both with and
    /// without groups.
    fn case2(with_groups: bool) -> Diagram {
        let groups = [
            ("request", "Request", &["client", "gateway"][..]),
            ("batch", "Batcher", &["batcher", "router"][..]),
            ("step", "Decode step", &["attn", "kv", "moe", "mhc", "sampler"][..]),
            ("out", "Output", &["detok", "stream", "tail", "peer"][..]),
        ];
        let names: Vec<&str> = groups.iter().flat_map(|g| g.2.iter().copied()).collect();
        let mut d = Diagram {
            kind: Kind::Sequence,
            title: "Decode step".into(),
            ..Default::default()
        };
        for n in names {
            d.nodes.push(Node {
                id: n.into(),
                label: n.into(),
                group: if with_groups {
                    groups
                        .iter()
                        .find(|g| g.2.contains(&n))
                        .map(|g| g.0.to_string())
                } else {
                    None
                },
                ..Default::default()
            });
        }
        for g in groups {
            d.groups.push(Group {
                id: g.0.into(),
                label: g.1.into(),
            });
        }
        let msgs = [
            ("client", "gateway", "open stream"),
            ("gateway", "batcher", "enqueue"),
            ("batcher", "router", "schedule batch 40 ms"),
            ("router", "attn", "prefill 8 tok/s"),
            ("attn", "kv", "write 1.3 GB"),
            ("kv", "moe", "route 4x"),
            ("moe", "mhc", "gather 1550 ms"),
            ("mhc", "sampler", "sample 36 ms"),
            ("sampler", "detok", "detokenize 12 ms"),
            ("detok", "stream", "emit chunk 8 tok/s"),
            ("stream", "client", "render 1000+ tok/s"),
        ];
        for (from, to, label) in msgs {
            d.edges.push(Edge {
                from: from.into(),
                to: to.into(),
                label: Some(label.into()),
                style: EdgeStyle::Solid,
            });
        }
        d
    }

    /// The screenshot's case 1: a right-ward chain too wide for the column.
    fn case1() -> Diagram {
        let mut d: Diagram = serde_json::from_value(serde_json::json!({
            "kind": "flow", "direction": "right",
            "nodes": [
                {"id": "pre", "label": "Prefill 1.7 s"},
                {"id": "mla", "label": "MLA attention 1550 ms"},
                {"id": "kda", "label": "KDA 57 ms"},
                {"id": "lm", "label": "LM head 36 ms"},
                {"id": "moe", "label": "MoE 13 ms"},
                {"id": "mhc", "label": "MHC 10 ms"},
                {"id": "end", "label": "Sample 10 ms"}
            ],
            "edges": [
                {"from": "pre", "to": "mla"}, {"from": "mla", "to": "kda"},
                {"from": "kda", "to": "lm"}, {"from": "lm", "to": "moe"},
                {"from": "moe", "to": "mhc"}, {"from": "mhc", "to": "end"}
            ]
        }))
        .unwrap();
        d
    }

    #[test]
    fn a_too_wide_flow_right_reruns_as_down_and_fits() {
        let mut d = case1();
        d.finish(Path::new("/"));
        let full = d.layout.as_ref().unwrap();
        assert!(full.width * MIN_SCALE > INLINE_W, "fixture is too wide at {}", full.width);
        let inline = d.inline.as_ref().expect("a rerun as down should fit");
        assert!(inline.width * MIN_SCALE <= INLINE_W, "inline width {}", inline.width);
        // Same nodes in the compact form, laid out top-down.
        assert_eq!(inline.nodes.len(), 7);
        let xs: Vec<f32> = inline.nodes.iter().map(|b| b.x).collect();
        let ys: Vec<f32> = inline.nodes.iter().map(|b| b.y).collect();
        assert!(ys.windows(2).all(|w| w[1] >= w[0]), "stacks downward: {ys:?}");
        assert!(xs.windows(2).any(|w| w[1] < w[0]), "not one long right-ward row");
    }

    #[test]
    fn thirteen_participants_without_groups_warns_and_crops() {
        let mut d = case2(false);
        let warnings = d.finish(Path::new("/"));
        assert!(
            warnings.iter().any(|w| w == "13 participants won't fit at 720pt. Give nodes a `group` (≤6 groups) or split the diagram."),
            "{warnings:?}"
        );
        assert!(d.inline.is_none());
        // The full layout is untouched: the client crops it and offers expand.
        assert!(d.layout.as_ref().unwrap().width * MIN_SCALE > INLINE_W);
    }

    #[test]
    fn thirteen_participants_with_six_groups_fold_into_lanes() {
        let mut d = case2(true);
        d.finish(Path::new("/"));
        let inline = d.inline.as_ref().expect("groups fold into lanes");
        assert!(inline.width * MIN_SCALE <= INLINE_W, "width {}", inline.width);
        // 4 lanes (request, batch, step, out) - the spec's folded form.
        assert_eq!(inline.nodes.len(), 4);
        // Between-group messages kept: open stream, enqueue, schedule batch, detokenize, render.
        // In-group runs fold into bundle rows with the numbers hoisted.
        let bundles: Vec<&Bundle> = inline.edges.iter().filter_map(|p| p.bundle.as_ref()).collect();
        assert!(bundles.len() >= 2, "the in-group runs bundle: {bundles:?}");
        let bundle_label = bundles.iter().map(|b| b.label.as_str()).collect::<Vec<_>>().join("|");
        assert!(bundle_label.contains("8 tok/s"), "{bundle_label}");
        // Every number survives the fold, in bundles or on kept arrows.
        let all_text = inline
            .edges
            .iter()
            .map(|p| {
                p.bundle.as_ref().map(|b| b.label.clone()).unwrap_or_else(|| {
                    d.edges[p.edge].label.clone().unwrap_or_default()
                })
            })
            .collect::<Vec<_>>()
            .join("|");
        assert!(all_text.contains("40 ms"), "{all_text}");
        assert!(all_text.contains("1000+ tok/s"), "{all_text}");
        // Between-lane messages stay as plain arrows.
        assert!(inline.edges.iter().any(|p| p.bundle.is_none()), "between-lane messages stay");
        // Lanes ordered as the groups were declared, left to right.
        let xs: Vec<f32> = inline.nodes.iter().map(|b| b.x).collect();
        assert!(xs.windows(2).all(|w| w[1] > w[0]));
    }

    #[test]
    fn a_run_of_numbered_in_group_messages_bundles_with_its_numbers() {
        let mut d = case2(true);
        // Trim to a small grouped sequence so the fold is exercised directly.
        d.finish(Path::new("/"));
        let inline = d.inline.as_ref().unwrap();
        // The decode-step lane (attn, kv, moe, mhc, sampler) holds a run of 4 numbered
        // messages: one bundle, all four numbers in its label, in order.
        let b = inline
            .edges
            .iter()
            .filter_map(|p| p.bundle.as_ref())
            .find(|b| b.count == 4)
            .expect("the 4-message run folds into one bundle");
        assert_eq!(
            b.label, "1.3 GB · 4x · 1550 ms · 36 ms",
            "numbers hoisted in order"
        );
        assert!(carries_number("1550 ms") && !carries_number("no number here"));
        assert_eq!(
            hoist_numbers("batch 40 ms then 8 tok/s").as_deref(),
            Some("40 ms · 8 tok/s")
        );
        assert_eq!(hoist_numbers("1000+ tok/s").as_deref(), Some("1000+ tok/s"));
    }

    #[test]
    fn folding_tells_the_model_what_it_shows() {
        let mut d = case2(true);
        let warnings = d.finish(Path::new("/"));
        let note = warnings
            .iter()
            .find(|w| w.starts_with("Shown folded:"))
            .expect("the model is told what's on screen");
        assert_eq!(note, "Shown folded: 13 participants in 4 lanes, 11 messages in 7 rows (3 bundles).");
        // A too-wide flow says nothing about folding; it just comes back as a different form.
        let mut flow = case1();
        let warnings = flow.finish(Path::new("/"));
        assert!(warnings.is_empty(), "{warnings:?}");
        assert!(flow.inline.is_some());
    }

    #[test]
    fn an_inline_form_is_never_wider_than_the_column_allows() {
        // Whatever the input, `inline` either fits at the floor or isn't there at all: the
        // client's crop-and-expand is the fallback, never a tiny drawing.
        let mut cases = vec![case1(), case2(true), case2(false)];
        // Seven groups: too many lanes, so it must refuse rather than emit a wide fold.
        let mut seven = case2(true);
        seven.groups.push(Group { id: "extra".into(), label: "Extra".into() });
        seven.nodes.push(Node {
            id: "spare".into(),
            label: "spare".into(),
            group: Some("extra".into()),
            ..Default::default()
        });
        cases.push(seven);
        // A top-down flow too wide to fit: no rerun helps, so no inline form.
        let mut down = case1();
        down.direction = Direction::Down;
        cases.push(down);
        for mut d in cases {
            d.finish(Path::new("/"));
            if let Some(l) = &d.inline {
                assert!(
                    l.width * MIN_SCALE <= INLINE_W + 0.01,
                    "inline {}pt is too wide ({} nodes)",
                    l.width,
                    l.nodes.len()
                );
            }
        }
    }

    #[test]
    fn six_lanes_with_compact_columns_fit_under_704() {
        // Six participants, no groups: compact columns alone bring it under the column.
        let mut d: Diagram = serde_json::from_value(serde_json::json!({
            "kind": "sequence",
            "nodes": [
                {"id": "a", "label": "Client"}, {"id": "b", "label": "Gateway"},
                {"id": "c", "label": "Batcher"}, {"id": "d", "label": "Router"},
                {"id": "e", "label": "Sampler"}, {"id": "f", "label": "Detok"}
            ],
            "edges": [
                {"from": "a", "to": "b", "label": "open"},
                {"from": "b", "to": "c", "label": "enqueue"},
                {"from": "c", "to": "d", "label": "schedule"},
                {"from": "d", "to": "e", "label": "prefill 8 tok/s"},
                {"from": "e", "to": "f", "label": "emit 1000+"}
            ]
        }))
        .unwrap();
        d.finish(Path::new("/"));
        let l = d.layout.as_ref().unwrap();
        assert!(l.width * MIN_SCALE <= INLINE_W, "6 lanes: {}pt wide", l.width);
        // A small sequence still fits and keeps its full layout unchanged.
        assert!(d.inline.is_none());
    }

    #[test]
    fn an_old_transcript_without_inline_still_decodes() {
        let old = r#"{"kind":"sequence","title":"t","nodes":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"edges":[{"from":"a","to":"b","label":"hi"}],"layout":{"width":400.0,"height":200.0,"nodes":[],"edges":[]},"mermaid":"sequenceDiagram"}"#;
        let d: Diagram = serde_json::from_str(old).unwrap();
        assert!(d.inline.is_none());
        assert_eq!(d.nodes.len(), 2);
        // And a fresh one round-trips with the field.
        let d2: Diagram = serde_json::from_str(r#"{"kind":"flow","nodes":[{"id":"a","label":"A"}],"edges":[],"inline":{"width":1.0,"height":1.0,"nodes":[],"edges":[]}}"#).unwrap();
        assert!(d2.inline.is_some());
    }
}
