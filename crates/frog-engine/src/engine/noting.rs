//! The engine's side of noting on its own (`crate::noting` is the pure part): the setting, the
//! evidence a proposal is checked against, writing the note, its receipt, its undo, and
//! "Make it a rule" through the usual `Customize` card.

use super::*;
use crate::customize::{self as cz, Change, LineOp, Target};
use crate::memory::{Note, Scope};
use crate::noting::{self, Evidence, Kind};
use anyhow::Context as _;

/// Undo handles for notes start with this; the rest says which note and what was written, so
/// undo works after a restart (from a replayed receipt) and never removes a note edited since.
const UNDO_PREFIX: &str = "note:";

/// The largest file a `read` note is checked against.
const MAX_FILE: u64 = 1 << 20;

impl Agent {
    /// Whether Frog notes things on its own in this session: never for a subagent or a session
    /// another one started (its "user" is an agent), nor on a small model, which can't do it
    /// reliably; otherwise the app's `auto-note` setting, else config, else on.
    pub(super) fn auto_note(&self) -> bool {
        if !self.top_level()
            || self.memory.is_none()
            || self.harness.tier == Tier::Weak
            || !self.shared.client_notes.load(Ordering::Relaxed)
        {
            return false;
        }
        match self.shared.settings.lock().unwrap().get(noting::SETTING) {
            Some(Value::Bool(on)) => *on,
            _ => self.cfg.memory.auto_note.unwrap_or(true),
        }
    }

    /// Remember the files a `Read` call opens, as candidates for a `read` note.
    pub(super) fn note_reads(&mut self, input: &Value) {
        let mut paths: Vec<&str> = input["file_path"].as_str().into_iter().collect();
        if let Some(files) = input["files"].as_array() {
            paths.extend(
                files
                    .iter()
                    .filter_map(|f| f.as_str().or(f["file_path"].as_str())),
            );
        }
        for p in paths {
            let path = self.ctx.resolve(p);
            self.read_by_frog
                .insert(std::fs::canonicalize(&path).unwrap_or(path));
        }
    }

    /// The `Note` tool: check the proposal, keep it, and emit the receipt.
    pub(super) fn note(&mut self, item: &str, input: &Value) -> Result<tools::Output> {
        if !self.auto_note() {
            anyhow::bail!("Not noted: noting on its own is off here. Don't retry.");
        }
        if self.remembered || (self.active_turn.is_some() && self.noted_turn == self.active_turn) {
            anyhow::bail!("Not noted: one note a turn, and this turn has one. Don't retry.");
        }
        let p = noting::parse(input).map_err(|r| anyhow::anyhow!(r.0))?;
        let (file, from) = match p.kind {
            Kind::Read => match self.read_file_for_note(&p.path) {
                Some((text, rel)) => (Some(text), Some(rel)),
                None => (None, None),
            },
            _ => (None, None),
        };
        let ev = Evidence {
            user: &self.user_words,
            file: file.as_deref(),
            notes: &self.notes,
            project: !self.chat,
        };
        let (text, scope) = noting::check(&p, &ev).map_err(|r| anyhow::anyhow!(r.0))?;
        let store = self.memory.as_ref().context("no notes here")?;
        store.set_session(&self.conv.session_id, &self.title());
        let note = store.add_noted(
            scope,
            &text,
            p.kind.label(),
            self.active_turn,
            from.as_deref(),
        )?;
        self.noted_turn = self.active_turn;
        // The list, not the prompt: rebuilding the system prompt mid-session would re-prefill
        // everything after it, and this conversation already has the fact.
        self.notes = store.load();
        self.emit_noted(item, &note, p.kind.label());
        Ok(tools::Output::text(
            "Noted. The user sees it under your reply and can undo it; don't mention it.",
        ))
    }

    /// The text of a file in the project that `Read` opened this session, and its path
    /// relative to the project. `None` for anything else: outside the project, never read,
    /// too big, or not text.
    fn read_file_for_note(&self, path: &str) -> Option<(String, String)> {
        if path.is_empty() {
            return None;
        }
        let abs = std::fs::canonicalize(self.ctx.resolve(path)).ok()?;
        let root = std::fs::canonicalize(&self.root).ok()?;
        if !abs.starts_with(&root) || !self.read_by_frog.contains(&abs) {
            return None;
        }
        if std::fs::metadata(&abs).ok()?.len() > MAX_FILE {
            return None;
        }
        let text = std::fs::read_to_string(&abs).ok()?;
        let rel = abs.strip_prefix(&root).ok()?.display().to_string();
        Some((text, rel))
    }

    /// The receipt for a note just kept.
    pub(super) fn emit_noted(&self, item: &str, note: &Note, source: &str) {
        let place = match note.scope {
            Scope::Global => "everywhere".to_string(),
            Scope::Project => self
                .memory
                .as_ref()
                .and_then(|m| m.project_name())
                .unwrap_or("this project")
                .to_string(),
        };
        self.emit(Event::Noted {
            item: item.into(),
            turn: self.active_turn,
            id: note.id.clone(),
            text: note.body.clone(),
            scope: match note.scope {
                Scope::Global => "everywhere",
                Scope::Project => "project",
            }
            .into(),
            place,
            source: source.into(),
            from: note.from.clone(),
            undo: undo_handle(note),
        });
    }

    /// Undo a note's receipt: remove exactly that note, unless it was edited since.
    pub(super) fn undo_note(&mut self, handle: &str) -> Option<Result<String>> {
        let rest = handle.strip_prefix(UNDO_PREFIX)?;
        Some((|| {
            let mut parts = rest.splitn(3, ':');
            let (scope, hash, id) = (parts.next(), parts.next(), parts.next());
            let (Some(scope), Some(hash), Some(id)) = (scope, hash, id) else {
                anyhow::bail!("that isn't an undo handle");
            };
            let scope = match scope {
                "project" => Scope::Project,
                "everywhere" => Scope::Global,
                _ => anyhow::bail!("that isn't an undo handle"),
            };
            let store = self.memory.as_ref().context("no notes here")?;
            let note = store
                .get(scope, id)
                .context("that note is already gone (undone or forgotten)")?;
            // Only a note Frog wrote on its own: never one the user wrote or kept by asking.
            if note.source != "frog" || note.kind.is_none() {
                anyhow::bail!("Frog didn't write that note on its own, so it was left as it is");
            }
            // Moved aside, then checked: an edit landing in between is put back, not lost.
            // Undone once, the note is gone, so the handle can't be used again.
            if !cz::remove_if(&note.path, |bytes| format!("{:016x}", fnv(bytes)) == hash)? {
                anyhow::bail!("the note was edited since, so it was left as it is");
            }
            self.notes = store.load();
            Ok("Undone.".to_string())
        })())
    }

    /// [`Op::NoteToRule`]: propose the note as a rule on the `Customize` card; on approval add
    /// the line, remove the note, and emit `customize_applied` whose undo puts both back.
    pub(super) async fn note_to_rule(&mut self, id: &str, scope: &str, place: Option<&str>) {
        let result = self.note_to_rule_inner(id, scope, place).await;
        if let Err(e) = result {
            self.notice(Level::Warn, format!("Couldn't make it a rule: {e:#}"));
        }
    }

    async fn note_to_rule_inner(
        &mut self,
        id: &str,
        scope: &str,
        place: Option<&str>,
    ) -> Result<()> {
        if !self.top_level() {
            anyhow::bail!("a session another session started can't change rules");
        }
        let scope = if scope == "everywhere" {
            Scope::Global
        } else {
            Scope::Project
        };
        let store = self.memory.as_ref().context("no notes here")?;
        let note = store
            .get(scope, id)
            .context("that note is gone (undone or forgotten)")?;
        let target = match place {
            Some("home") => Target::Home,
            _ if self.chat => Target::Home,
            _ => Target::Project,
        };
        let line = note.first_line().to_string();
        let change = Change::Line {
            op: LineOp::Add,
            target,
            line: line.clone(),
            to: None,
        };
        // The user pressed "Make it a rule" on the note: that button, as labelled, is the ask.
        let asked_by = crate::protocol::AskedBy {
            who: "user".into(),
            words: "Make it a rule".into(),
        };
        let mut card = self.plan(&change, asked_by)?.card;
        card.title = "Make this a rule?".into();
        card.primary = "Add rule".into();
        let item = format!("note:{id}");
        if !matches!(
            self.propose(&item, &card).await?,
            super::customize::Answer::Took(_)
        ) {
            return Ok(());
        }
        let rule = match self.apply_change(&change)? {
            cz::Undo::File(f) => f,
            _ => anyhow::bail!("unexpected undo"),
        };
        let note_undo = cz::write_file(&note.path, None, true)?;
        let handle = new_id();
        self.undos
            .insert(handle.clone(), cz::Undo::Files(vec![rule, note_undo]));
        self.customize_reload();
        self.emit(Event::CustomizeApplied {
            item,
            undo: handle,
            card: Box::new(card),
        });
        Ok(())
    }
}

/// `note:<scope>:<hash of the file as written>:<id>`.
fn undo_handle(note: &Note) -> String {
    let bytes = std::fs::read(&note.path).unwrap_or_default();
    format!(
        "{UNDO_PREFIX}{}:{:016x}:{}",
        match note.scope {
            Scope::Global => "everywhere",
            Scope::Project => "project",
        },
        fnv(&bytes),
        note.id
    )
}

/// FNV-1a: stable across runs and builds, unlike `DefaultHasher`.
pub(super) fn fnv(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |h, b| {
        (h ^ u64::from(*b)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

// ---- bringing back only what fits ----

/// At most this many notes come back in a turn.
const PER_TURN_MAX: usize = 5;

impl Agent {
    /// Bring the notes' vectors up to date with `notes`; `None` (the whole index in the prompt)
    /// for a subagent, without a store, or when the index can't be written.
    pub(super) fn sync_note_index(&mut self) {
        self.note_index = match (&self.memory, self.subagent) {
            (Some(store), false) => crate::memvec::Index::sync(store, &self.notes).ok(),
            _ => None,
        };
    }

    /// The notes that fit this turn, as a block for the user's message (only the ones not
    /// already in the conversation), with a `used_notes` event and their last use recorded.
    pub(super) fn notes_for_turn(&mut self, turn: u64, words: &str, files: &[String]) -> String {
        if self.subagent {
            return String::new();
        }
        if !self.notes_per_turn || self.notes.is_empty() {
            return String::new();
        }
        self.sync_note_index();
        let Some(index) = &self.note_index else {
            return String::new();
        };
        let budget = match self.harness.tier {
            Tier::Weak => 120,
            Tier::Medium => 250,
            Tier::Strong => 400,
        };
        let mut files: Vec<String> = files.to_vec();
        files.extend(
            self.read_by_frog
                .iter()
                .filter_map(|p| p.strip_prefix(&self.root).ok())
                .map(|p| p.display().to_string()),
        );
        // The prompt already carries standing guidance; choose among the rest.
        let rest: Vec<Note> = self
            .notes
            .iter()
            .filter(|n| !self.notes_in_prompt.contains(&note_key(n.scope, &n.id)))
            .cloned()
            .collect();
        let chosen = crate::memvec::choose(&rest, index, words, &files, PER_TURN_MAX, budget);
        if chosen.is_empty() {
            return String::new();
        }
        let key = note_key;
        let picked: Vec<&Note> = chosen
            .iter()
            .filter_map(|c| {
                self.notes
                    .iter()
                    .find(|n| n.scope == c.scope && n.id == c.id)
            })
            .collect();
        let fresh: Vec<&Note> = picked
            .iter()
            .copied()
            .filter(|n| !self.notes_sent.contains(&key(n.scope, &n.id)))
            .collect();
        let block = crate::memory::turn_block(&fresh);
        let used: Vec<crate::protocol::UsedNote> = picked
            .iter()
            .map(|n| crate::protocol::UsedNote {
                id: n.id.clone(),
                scope: if n.scope == Scope::Global {
                    "everywhere"
                } else {
                    "project"
                }
                .into(),
                text: n.first_line().to_string(),
            })
            .collect();
        let marks: Vec<(Scope, String)> = picked.iter().map(|n| (n.scope, n.id.clone())).collect();
        for n in &fresh {
            self.notes_sent.insert(key(n.scope, &n.id));
        }
        let now = chrono::Local::now()
            .format("%Y-%m-%dT%H:%M:%S%:z")
            .to_string();
        if let Some(index) = &mut self.note_index {
            let _ = index.mark_used(&marks, &now);
        }
        self.emit(Event::UsedNotes {
            turn,
            notes: used,
            tokens: self.est.tokens(block.len()) as u64,
        });
        block
    }
}

fn note_key(s: Scope, id: &str) -> String {
    format!("{}:{id}", if s == Scope::Global { "g" } else { "p" })
}

impl Agent {
    /// The notes' part of the system prompt. A store that fits [`crate::memory::whole_budget`]
    /// rides whole, so every note applies whatever the message's words. Past it (with vectors
    /// to choose by), only standing guidance rides, within that budget, and the rest come back
    /// per turn. Without vectors, the whole index within the model's budget, as before.
    pub(super) fn place_notes(&mut self) {
        self.notes_in_prompt.clear();
        let small = crate::memory::whole_budget(self.harness.tier);
        let (_, _, over) = crate::memory::index_within(&self.notes, small);
        self.notes_per_turn = self.note_index.is_some() && over > 0;
        let (index, each, omitted) = if self.notes_per_turn {
            let standing: Vec<Note> = self
                .notes
                .iter()
                .filter(|n| crate::memory::standing(n))
                .cloned()
                .collect();
            crate::memory::index_within(&standing, small)
        } else {
            crate::memory::index_parts(&self.notes, self.harness.tier, self.window)
        };
        for (id, scope, line) in &each {
            if line.is_some() {
                self.notes_in_prompt.insert(note_key(*scope, id));
            }
        }
        self.system.push_str(&index);
        if self.notes_per_turn {
            self.system.push_str(crate::memory::PER_TURN);
            self.notes_omitted = 0;
        } else {
            self.notes_omitted = omitted;
        }
    }
}
