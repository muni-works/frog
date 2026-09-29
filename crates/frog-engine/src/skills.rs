//! Agent Skills (agentskills.io): directories with a `SKILL.md` (YAML frontmatter with `name` and
//! `description`, then instructions), loaded progressively. The model sees a compact catalog,
//! loads a skill's instructions with the `Skill` tool when a task matches, and reads the skill's
//! other files only if the instructions call for them. `/skill-name` in a message loads one
//! directly.
//!
//! Scanned, project first (a project skill shadows a user one of the same name):
//! `<project>/{.frog,.agents,.claude}/skills/*/SKILL.md`, then
//! `~/.config/frog/skills`, `~/.agents/skills`, `~/.claude/skills`.

use crate::provider::ToolSpec;
use crate::tools::Output;
use anyhow::{Result, bail};
use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const TOOL: &str = "Skill";

/// The catalog's share of the system prompt, in characters (~1.5k tokens). Past it, skills are
/// listed by name only, and the model searches descriptions with the tool.
const CATALOG_BUDGET: usize = 6_000;

#[derive(Clone, Debug, Serialize)]
pub struct Skill {
    pub name: String,
    pub description: String,
    /// The `SKILL.md` file.
    pub path: PathBuf,
    /// Found under the project, rather than the user's home.
    pub project: bool,
}

impl Skill {
    pub fn dir(&self) -> &Path {
        self.path.parent().unwrap_or(Path::new("."))
    }
}

/// Every skill visible from `cwd`, by name.
pub fn discover(cwd: &Path) -> BTreeMap<String, Skill> {
    discover_in(cwd, true)
}

/// Skills visible from `cwd`: the project's, and the user's own unless `user` is false.
pub fn discover_in(cwd: &Path, user: bool) -> BTreeMap<String, Skill> {
    let home = dirs::home_dir().unwrap_or_default();
    let mut roots: Vec<(PathBuf, bool)> = [".frog", ".agents", ".claude"]
        .iter()
        .map(|d| (cwd.join(d).join("skills"), true))
        .collect();
    if user {
        roots.push((crate::config::config_dir().join("skills"), false));
        roots.push((home.join(".agents/skills"), false));
        roots.push((home.join(".claude/skills"), false));
    }

    let mut out = BTreeMap::new();
    for (root, project) in roots {
        let Ok(entries) = std::fs::read_dir(&root) else {
            continue;
        };
        let mut dirs: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
        dirs.sort();
        for dir in dirs {
            let path = dir.join("SKILL.md");
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            let Some((meta, _)) = split(&text) else {
                continue;
            };
            let fallback = dir.file_name().map(|n| n.to_string_lossy().into_owned());
            let Some(name) = meta.get("name").cloned().or(fallback) else {
                continue;
            };
            // A description is what the model chooses by; without one, a skill is unusable.
            let Some(description) = meta.get("description").filter(|d| !d.trim().is_empty()) else {
                continue;
            };
            if meta.get("disable-model-invocation").map(String::as_str) == Some("true") {
                continue;
            }
            // First found wins, and projects are scanned first.
            out.entry(name.clone()).or_insert(Skill {
                name,
                description: description.trim().to_string(),
                path,
                project,
            });
        }
    }
    out
}

/// The frontmatter's top-level string fields and the body. Lenient, like other clients: plain,
/// quoted and folded (`>`/`|`) values, and unquoted values that contain colons.
pub fn split(text: &str) -> Option<(BTreeMap<String, String>, &str)> {
    let rest = text.strip_prefix("---")?;
    let rest = rest.strip_prefix('\r').unwrap_or(rest).strip_prefix('\n')?;
    let end = rest.find("\n---")?;
    let (yaml, after) = (&rest[..end], &rest[end + 4..]);
    let body = after.split_once('\n').map(|(_, b)| b).unwrap_or("");

    let mut map = BTreeMap::new();
    let lines: Vec<&str> = yaml.lines().collect();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        i += 1;
        if line.starts_with([' ', '\t', '#']) || line.trim().is_empty() {
            continue;
        }
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim();
        let value = if matches!(value, ">" | "|" | ">-" | "|-" | ">+" | "|+") {
            // A block scalar: the indented lines that follow.
            let mut parts = Vec::new();
            while i < lines.len() && (lines[i].starts_with([' ', '\t']) || lines[i].is_empty()) {
                parts.push(lines[i].trim());
                i += 1;
            }
            let sep = if value.starts_with('>') { " " } else { "\n" };
            parts.join(sep).trim().to_string()
        } else {
            let unquoted = value
                .strip_prefix('"')
                .and_then(|v| v.strip_suffix('"'))
                .or_else(|| value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
                .unwrap_or(value);
            unquoted.to_string()
        };
        map.insert(key.trim().to_string(), value);
    }
    Some((map, body))
}

/// The catalog for the system prompt: every skill's name, with as much of its description as
/// fits the budget.
pub fn catalog(skills: &BTreeMap<String, Skill>) -> String {
    catalog_within(skills, CATALOG_BUDGET)
}

/// The catalog in about `budget` characters: names only (and search) when descriptions
/// wouldn't fit.
pub fn catalog_within(skills: &BTreeMap<String, Skill>, budget: usize) -> String {
    if skills.is_empty() {
        return String::new();
    }
    let per = budget / skills.len();
    let (list, search) = if per < 60 {
        let names: Vec<&str> = skills.keys().map(String::as_str).collect();
        (
            names.join(", "),
            format!(
                " There are too many to describe here; call `{TOOL}` with `query` to search their descriptions."
            ),
        )
    } else {
        let lines: Vec<String> = skills
            .values()
            .map(|s| {
                let room = per.min(300).saturating_sub(s.name.len() + 4).max(40);
                format!("- {}: {}", s.name, clip(&s.description, room))
            })
            .collect();
        (lines.join("\n"), String::new())
    };
    format!(
        "\n\n# Skills\nSkills are packaged instructions for specific tasks. When a task matches one, call `{TOOL}` with its name to load its instructions before you start, and follow them.{search} Users can also load one by starting a message with /skill-name.\n{list}"
    )
}

fn clip(s: &str, n: usize) -> String {
    let one = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if one.chars().count() <= n {
        return one;
    }
    format!(
        "{}…",
        one.chars().take(n.saturating_sub(1)).collect::<String>()
    )
}

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: TOOL.into(),
        description: "Load a skill's instructions (see Skills in the system prompt) before doing a task it covers. Pass `name` to load one, or `query` to search skills by keyword.".into(),
        schema: serde_json::json!({
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "The skill's name"},
                "query": {"type": "string", "description": "Keywords to search skill descriptions, instead of name"}
            }
        }),
    }
}

/// `Skill`: load a skill (once per session), or search the catalog.
pub fn run(
    skills: &BTreeMap<String, Skill>,
    loaded: &mut std::collections::HashSet<String>,
    input: &Value,
) -> Result<Output> {
    if let Some(q) = input["query"].as_str().filter(|q| !q.trim().is_empty()) {
        return Ok(Output::text(search(skills, q)));
    }
    let name = input["name"]
        .as_str()
        .unwrap_or("")
        .trim()
        .trim_start_matches('/');
    let Some(skill) = skills.get(name) else {
        if name.is_empty() {
            bail!("give a skill `name`, or a `query` to search");
        }
        bail!("no skill named `{name}`. {}", search(skills, name));
    };
    if !loaded.insert(skill.name.clone()) {
        return Ok(Output::text(format!(
            "The `{}` skill is already loaded earlier in this conversation; follow those instructions.",
            skill.name
        )));
    }
    let out = load(skill)?;
    Ok(Output {
        display: Some(format!("Loaded the {} skill", skill.name)),
        content: out,
        ..Default::default()
    })
}

/// A skill's instructions, wrapped so they're recognizable later, with its files listed (not read).
pub fn load(skill: &Skill) -> Result<String> {
    let text = std::fs::read_to_string(&skill.path)?;
    let body = split(&text).map(|(_, b)| b).unwrap_or(&text).trim();
    let dir = skill.dir();
    let mut files = Vec::new();
    for entry in walkdir(dir, 3) {
        if let Ok(rel) = entry.strip_prefix(dir)
            && rel != Path::new("SKILL.md")
        {
            files.push(rel.display().to_string());
        }
        if files.len() >= 40 {
            files.push("…".into());
            break;
        }
    }
    let resources = if files.is_empty() {
        String::new()
    } else {
        format!(
            "\n<skill_resources>\n{}\n</skill_resources>",
            files
                .iter()
                .map(|f| format!("  {f}"))
                .collect::<Vec<_>>()
                .join("\n")
        )
    };
    Ok(format!(
        "<skill_content name=\"{}\">\n{body}\n\nSkill directory: {}\nRelative paths in this skill are relative to that directory; use absolute paths in tool calls.{resources}\n</skill_content>",
        skill.name,
        dir.display()
    ))
}

fn search(skills: &BTreeMap<String, Skill>, query: &str) -> String {
    let words: Vec<String> = query.split_whitespace().map(str::to_lowercase).collect();
    let mut scored: Vec<(usize, &Skill)> = skills
        .values()
        .map(|s| {
            let (n, d) = (s.name.to_lowercase(), s.description.to_lowercase());
            let score = words
                .iter()
                .map(|w| 3 * n.contains(w.as_str()) as usize + d.contains(w.as_str()) as usize)
                .sum();
            (score, s)
        })
        .filter(|(score, _)| *score > 0)
        .collect();
    scored.sort_by_key(|(score, _)| std::cmp::Reverse(*score));
    if scored.is_empty() {
        return "No skills match; the full list is in the system prompt.".into();
    }
    let lines: Vec<String> = scored
        .iter()
        .take(8)
        .map(|(_, s)| format!("- {}: {}", s.name, clip(&s.description, 200)))
        .collect();
    format!(
        "Matching skills (load one with `name`):\n{}",
        lines.join("\n")
    )
}

/// A message that starts with `/skill-name` loads that skill: its instructions go ahead of
/// the rest of the message. Returns the expanded text and the skill's name.
pub fn expand_command(skills: &BTreeMap<String, Skill>, input: &str) -> Option<(String, String)> {
    let rest = input.trim_start().strip_prefix('/')?;
    let (name, args) = rest.split_once(char::is_whitespace).unwrap_or((rest, ""));
    let skill = skills.get(name)?;
    let content = load(skill).ok()?;
    let ask = if args.trim().is_empty() {
        format!("Use the {name} skill.")
    } else {
        args.trim().to_string()
    };
    Some((format!("{content}\n\n{ask}"), skill.name.clone()))
}

/// Files under `dir`, a few levels deep, skipping hidden and dependency folders.
fn walkdir(dir: &Path, depth: usize) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return out;
    };
    let mut entries: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
    entries.sort();
    for p in entries {
        let name = p
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        if name.starts_with('.') || name == "node_modules" || name == "__pycache__" {
            continue;
        }
        if p.is_dir() {
            if depth > 1 {
                out.extend(walkdir(&p, depth - 1));
            }
        } else {
            out.push(p);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_frontmatter_leniently() {
        let (m, body) = split("---\nname: pdf-tools\ndescription: Use this when: the user has PDFs\nmetadata:\n  author: x\n---\n# PDF\nsteps").unwrap();
        assert_eq!(m["name"], "pdf-tools");
        assert_eq!(m["description"], "Use this when: the user has PDFs");
        assert!(!m.contains_key("author"));
        assert_eq!(body, "# PDF\nsteps");

        let (m, _) = split("---\nname: 'x'\ndescription: >\n  folded\n  lines\n---\n").unwrap();
        assert_eq!(m["name"], "x");
        assert_eq!(m["description"], "folded lines");
        assert!(split("no frontmatter").is_none());
    }

    #[test]
    fn discovers_project_skills_over_user_ones_and_loads_them() {
        let dir = std::env::temp_dir().join(format!("frog-skills-{}", crate::session::new_id()));
        let skill = dir.join(".agents/skills/release-notes");
        std::fs::create_dir_all(skill.join("scripts")).unwrap();
        std::fs::write(
            skill.join("SKILL.md"),
            "---\nname: release-notes\ndescription: Write release notes from git history.\n---\nRun scripts/log.sh first.",
        )
        .unwrap();
        std::fs::write(skill.join("scripts/log.sh"), "git log").unwrap();
        let all = discover(&dir);
        let s = &all["release-notes"];
        assert!(s.project);
        let content = load(s).unwrap();
        assert!(content.contains("<skill_content name=\"release-notes\">"));
        assert!(content.contains("Run scripts/log.sh first."));
        assert!(content.contains("scripts/log.sh"));
        assert!(!content.contains("description:"));

        let mut loaded = std::collections::HashSet::new();
        let first = run(
            &all,
            &mut loaded,
            &serde_json::json!({"name": "release-notes"}),
        )
        .unwrap();
        assert!(first.content.contains("skill_content"));
        let again = run(
            &all,
            &mut loaded,
            &serde_json::json!({"name": "release-notes"}),
        )
        .unwrap();
        assert!(again.content.contains("already loaded"));

        let (text, name) = expand_command(&all, "/release-notes for v2").unwrap();
        assert_eq!(name, "release-notes");
        assert!(text.ends_with("for v2"));
        assert!(expand_command(&all, "/nope hi").is_none());
        assert!(catalog(&all).contains("release-notes: Write release notes"));
    }
}
