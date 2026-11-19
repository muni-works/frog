//! Customize in a live session: the snapshot measured against this session's model and
//! connections, and changes applied so the next turn's prompt reflects them.

use super::*;

impl Agent {
    /// Log a use of a skill or a connection's tool, for Customize's strip and "last used".
    pub(super) fn record_use(&self, kind: crate::customize::usage::Kind, key: &str) {
        crate::customize::usage::record(kind, key, &self.conv.session_id, &self.title());
    }

    /// Log a use of the skill named `name`, if there is one.
    pub(super) fn record_skill_use(&self, name: &str) {
        if let Some(s) = self.skills.get(name) {
            self.record_use(crate::customize::usage::Kind::Skill, &s.id());
        }
    }

    /// Answer [`Op::Customize`] (and every change) with the snapshot as things are now.
    pub(super) fn emit_customize(&mut self, error: Option<String>) {
        if self.subagent {
            return;
        }
        let connecting: Vec<String> = self.mcp_connecting.iter().cloned().collect();
        let report = crate::customize::report(&crate::customize::Ctx {
            cfg: &self.cfg,
            cwd: &self.root,
            chat: self.chat,
            est: self.est,
            calibrated: self.est.chars_per_token != Estimator::default().chars_per_token,
            tier: self.harness.tier,
            window: self.window,
            small_window: self.small_window(),
            hub: Some(&self.mcp),
            connecting: &connecting,
            connected: true,
            memory: self.memory.as_ref(),
        });
        self.emit(Event::Customize {
            report: Box::new(report),
            error,
        });
    }

    /// A Customize page changed something: make the change, re-read what it touched so the
    /// next turn's prompt carries it, and answer with the new snapshot.
    pub(super) fn customize_change(&mut self, change: crate::customize::Change) {
        if self.subagent {
            return;
        }
        let applied = crate::customize::apply(
            &self.cfg,
            &self.root,
            self.chat,
            self.memory.as_ref(),
            &change,
        );
        if let Err(e) = applied {
            self.emit_customize(Some(format!("{e:#}")));
            return;
        }
        match change.kind() {
            "skills" if !self.subagent => {
                self.skills = crate::skills::discover_in(&self.root, !self.cfg.hermetic);
            }
            "rules" if !self.chat => self.rules = crate::rules::discover(&self.root),
            "memory" => {
                if let Some(store) = &self.memory {
                    self.notes = store.load();
                }
            }
            // Tools and connections are filtered where the catalog is built, on every call.
            _ => {}
        }
        self.sync_specs();
        self.apply_harness();
        self.emit_customize(None);
    }
}
