//! Cam's digest (docs/design/delegation.md): the day's roll-up of what the
//! delegation pipeline did — what the second pass allowed on context, what the
//! chief decided, what still carded the user. One counter per path; advisory
//! (in memory, lost on crash). The daily notice fires at most once per day,
//! at the first card after midnight, so days with no cards stay silent.

use std::sync::LazyLock;

/// The day's counters.
#[derive(Default, Clone, Copy)]
pub struct Counts {    /// Calls the first classifier allowed.
    pub auto_allowed: u32,
    /// Calls the second pass upgraded to allow.
    pub second_pass: u32,
    /// Calls the chief approved.
    pub delegated_chief: u32,
    /// Calls the chief declined or couldn't be reached (they carded).
    pub chief_fallback: u32,
    /// Calls that carded the user: never-delegable, unclassed flags, denies.
    pub blocked: u32,
}

impl Counts {
    fn total(&self) -> u32 {
        self.auto_allowed + self.second_pass + self.delegated_chief + self.chief_fallback + self.blocked
    }
}

/// The digest: today's counters plus the day the notice last fired.
pub struct Digest {
    day: String,
    counts: Counts,
    noticed: Option<String>,
}

fn ymd() -> String {
    #[cfg(test)]
    if let Some(d) = test_ymd_override() {
        return d;
    }
    // Days since the epoch, UTC, as the key; midnight rollover by compare.
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{}", secs / 86_400)
}

impl Default for Digest {
    fn default() -> Self {
        Self {
            day: ymd(),
            counts: Counts::default(),
            noticed: None,
        }
    }
}

impl Digest {
    fn roll(&mut self) {
        let today = ymd();
        if self.day != today {
            self.day = today;
            self.counts = Counts::default();
            self.noticed = None;
        }
    }

    pub fn count(&mut self, which: Which) {
        self.roll();
        match which {
            Which::AutoAllowed => self.counts.auto_allowed += 1,
            Which::SecondPass => self.counts.second_pass += 1,
            Which::DelegatedChief => self.counts.delegated_chief += 1,
            Which::ChiefFallback => self.counts.chief_fallback += 1,
            Which::Blocked => self.counts.blocked += 1,
        }
    }

    /// Whether today's notice hasn't fired yet (the caller fires it, then marks).
    pub fn needs_daily_notice(&mut self) -> bool {
        self.roll();
        self.noticed.is_none() && self.counts.blocked > 0
    }

    pub fn mark_noticed(&mut self) {
        self.noticed = Some(self.day.clone());
    }

    /// The roll-up line for the app notice / `Op::Digest` / `frog digest`.
    pub fn summary(&mut self) -> String {
        self.roll();
        let c = self.counts;
        format!(
            "delegation today: {} auto-allowed, {} second-pass upgrades, {} chief-approved, {} chief fallbacks, {} carded ({} calls total)",
            c.auto_allowed, c.second_pass, c.delegated_chief, c.chief_fallback, c.blocked, c.total()
        )
    }
}

/// Which counter to bump.
#[derive(Clone, Copy)]
pub enum Which {
    AutoAllowed,
    SecondPass,
    DelegatedChief,
    ChiefFallback,
    Blocked,
}

/// Test-only: freeze the day key so rollover can be driven.
#[cfg(test)]
pub static TEST_DAY: LazyLock<std::sync::Mutex<Option<String>>> =
    LazyLock::new(|| std::sync::Mutex::new(None));

#[cfg(test)]
fn test_ymd_override() -> Option<String> {
    TEST_DAY.lock().unwrap().clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_roll_up_and_roll_over() {
        *TEST_DAY.lock().unwrap() = Some("20000".into());
        let mut d = Digest::default();
        d.count(Which::AutoAllowed);
        d.count(Which::AutoAllowed);
        d.count(Which::SecondPass);
        d.count(Which::DelegatedChief);
        d.count(Which::ChiefFallback);
        d.count(Which::Blocked);
        assert_eq!(
            d.summary(),
            "delegation today: 2 auto-allowed, 1 second-pass upgrades, 1 chief-approved, 1 chief fallbacks, 1 carded (6 calls total)"
        );
        // Midnight: everything resets, the notice re-arms.
        *TEST_DAY.lock().unwrap() = Some("20001".into());
        assert!(d.needs_daily_notice() == false, "no blocked calls today yet");
        d.count(Which::Blocked);
        assert!(d.needs_daily_notice());
        d.mark_noticed();
        assert!(!d.needs_daily_notice());
        *TEST_DAY.lock().unwrap() = None;
    }
}
