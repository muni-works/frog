//! Test-run summaries: when a command's output ends in a test runner's summary, the completed
//! command item carries the counts and the failing tests' names (docs/design/transcript/spec.md,
//! "Test runs"). The transcript's line then reads "10 of 11", and opened, names what failed.
//!
//! Recognised: cargo test, pytest, go test (`-v` only: plain `go test` prints no counts),
//! vitest and jest, from the tail of the output as the Bash tool keeps it (stdout, then stderr,
//! then `[exit code N]`). Each runner has its own check that the counts are whole; anything not
//! recognised with confidence yields `None`, never a guessed count. Output from two different
//! runners is `None` too: one figure can't stand for both.

use regex::Regex;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::sync::LazyLock;

/// How much of the end of the output is read. The Bash tool keeps at most 30 000 bytes (head
/// and tail around a truncation marker), so in practice this is all of what it kept.
const TAIL: usize = 32 * 1024;

/// A test run's counts, as the completed command item carries them (`tests`).
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq, JsonSchema)]
pub struct TestRun {
    /// `cargo`, `pytest`, `go`, `vitest` or `jest`.
    pub runner: String,
    pub passed: u32,
    pub failed: u32,
    /// Tests that ran: `passed + failed`. Skipped, ignored and filtered tests aren't counted.
    pub total: u32,
    /// The failing tests, as the runner names them, in its order. May be shorter than
    /// `failed` when the runner didn't print every name (or the output was cut); never longer.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub failed_names: Vec<String>,
}

/// The test run a command's output reports, if it's recognised with confidence.
pub fn parse(output: &str) -> Option<TestRun> {
    let text = prepare(output);
    let long = output.len() > TAIL;
    // Two runners' output (`cargo test; pytest`): one figure can't stand for both, wherever
    // in the output the other's summary sits.
    if runners_present(&text) > 1 {
        return None;
    }
    let found: Vec<TestRun> = [cargo, pytest, go, vitest, jest]
        .iter()
        .filter_map(|f| f(&text, long))
        .collect();
    match <[TestRun; 1]>::try_from(found) {
        Ok([one]) => Some(one),
        Err(_) => None,
    }
}

static ANSI: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\r").unwrap());
static EXIT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\n?\[exit code -?\d+\]\s*$").unwrap());
/// The Bash tool's mark where it dropped the middle of a long output (`truncate_middle`).
static CUT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^… \[\d+ bytes truncated\] …$").unwrap());

/// The output's tail, without colour codes or the `[exit code N]` line.
fn prepare(output: &str) -> String {
    let mut start = output.len().saturating_sub(TAIL);
    while !output.is_char_boundary(start) {
        start += 1;
    }
    let tail = &output[start..];
    // Start at a whole line.
    let tail = if start > 0 {
        tail.split_once('\n').map_or("", |(_, r)| r)
    } else {
        tail
    };
    let plain = ANSI.replace_all(tail, "");
    EXIT.replace(plain.trim_end(), "").trim_end().to_string()
}

/// Whether the output lost lines anywhere: its middle was dropped, or it's longer than the
/// tail read. Runners whose counts are spread through the output can't be trusted then.
fn cut(text: &str, long: bool) -> bool {
    long || CUT.is_match(text)
}

/// How many different runners left a summary line anywhere in the text.
fn runners_present(text: &str) -> usize {
    static GO_PACKAGE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?m)^(?:ok|FAIL)\s+\S+\s+[\d.]+s$").unwrap());
    [
        CARGO_RESULT.is_match(text),
        text.lines().any(|l| PYTEST_SUMMARY.is_match(l.trim())),
        GO_RESULT.is_match(text) || GO_PACKAGE.is_match(text),
        VITEST_TESTS.is_match(text),
        JEST_TESTS.is_match(text),
    ]
    .iter()
    .filter(|&&p| p)
    .count()
}

fn n(s: &str) -> u32 {
    s.parse().unwrap_or(0)
}

fn dedup(names: Vec<String>, cap: u32) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for name in names {
        if !out.contains(&name) {
            out.push(name);
        }
    }
    out.truncate(cap as usize);
    out
}

/// "N word, N word" (or `|`-separated) counts: the number for each word.
fn counts(s: &str) -> Vec<(String, u32)> {
    static PART: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(\d+) ([a-z]+)").unwrap());
    PART.captures_iter(s)
        .map(|c| (c[2].to_string(), n(&c[1])))
        .collect()
}

fn count(parts: &[(String, u32)], words: &[&str]) -> u32 {
    parts
        .iter()
        .filter(|(w, _)| words.contains(&w.as_str()))
        .map(|(_, k)| k)
        .sum()
}

// ---- cargo test ----

static CARGO_RUNNING: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^running (\d+) tests?$").unwrap());
static CARGO_RESULT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored; (\d+) measured; (\d+) filtered out(;.*)?$").unwrap()
});
static CARGO_TARGET: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^\s+(Running|Doc-tests) ").unwrap());
static CARGO_FAILURES: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^failures:\n((?:    \S.*\n)+)").unwrap());

/// cargo test prints one `running N tests` … `test result:` pair per test binary. Every pair
/// must be whole (N = passed + failed + ignored + measured), and when cargo's own `Running`
/// lines are there (stderr, after all the tests), one per binary.
fn cargo(text: &str, long: bool) -> Option<TestRun> {
    let results: Vec<_> = CARGO_RESULT.captures_iter(text).collect();
    if results.is_empty() || cut(text, long) {
        return None;
    }
    let running: Vec<u32> = CARGO_RUNNING
        .captures_iter(text)
        .map(|c| n(&c[1]))
        .collect();
    if running.len() != results.len() {
        return None;
    }
    let targets = CARGO_TARGET.find_iter(text).count();
    if targets != 0 && targets != results.len() {
        return None;
    }
    let (mut passed, mut failed) = (0, 0);
    for (r, &ran) in results.iter().zip(&running) {
        let (p, f, i, m) = (n(&r[2]), n(&r[3]), n(&r[4]), n(&r[5]));
        if p + f + i + m != ran || ((&r[1] == "ok") != (f == 0)) {
            return None;
        }
        passed += p;
        failed += f;
    }
    let names = CARGO_FAILURES
        .captures_iter(text)
        .flat_map(|c| {
            c[1].lines()
                .map(|l| l.trim().to_string())
                .collect::<Vec<_>>()
        })
        .collect();
    Some(TestRun {
        runner: "cargo".into(),
        passed,
        failed,
        total: passed + failed,
        failed_names: dedup(names, failed),
    })
}

// ---- pytest ----

static PYTEST_SUMMARY: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^=*\s*((?:\d+ (?:failed|passed|skipped|deselected|xfailed|xpassed|warnings?|errors?|rerun)(?:, )?)+) in [\d.]+s(?: \([^)]*\))?\s*=*$").unwrap()
});
static PYTEST_FAILED: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^(?:FAILED|ERROR) (\S+)").unwrap());

/// pytest writes everything to stdout and ends on its summary line: "== 2 failed, 4 passed in
/// 0.03s ==" (or without the rules, with `-q`). An interrupted run (a collection error) is
/// not a count of tests.
fn pytest(text: &str, _long: bool) -> Option<TestRun> {
    let last = text.lines().last()?.trim();
    let c = PYTEST_SUMMARY.captures(last)?;
    if text.contains("!!! Interrupted") {
        return None;
    }
    let parts = counts(&c[1]);
    let passed = count(&parts, &["passed", "xpassed"]);
    let failed = count(&parts, &["failed", "error", "errors"]);
    if passed + failed == 0 {
        return None;
    }
    let names = PYTEST_FAILED
        .captures_iter(text)
        .map(|c| c[1].to_string())
        .collect();
    Some(TestRun {
        runner: "pytest".into(),
        passed,
        failed,
        total: passed + failed,
        failed_names: dedup(names, failed),
    })
}

// ---- go test -v ----

static GO_RUN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^=== RUN   ([^/\s]+)$").unwrap());
static GO_RESULT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^--- (PASS|FAIL|SKIP): (\S+) \(").unwrap());
static GO_END: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(?:ok\s+\S+\s+(?:[\d.]+s|\(cached\)).*|FAIL\s+\S+\s+[\d.]+s|FAIL|PASS|\?\s+\S+\s+\[no test files\])$").unwrap()
});

/// `go test -v` prints `=== RUN` and `--- PASS/FAIL/SKIP` for every top-level test, then a
/// package line. Plain `go test` lists only failures, so it has no total and isn't counted.
/// Each top-level test that started must have a result, and the output must end on go's own
/// package line; a package that didn't build means tests that never ran.
fn go(text: &str, long: bool) -> Option<TestRun> {
    let last = text.lines().last()?.trim_end();
    if !GO_END.is_match(last) || cut(text, long) {
        return None;
    }
    if text.contains("[build failed]") || text.contains("[setup failed]") {
        return None;
    }
    let runs = GO_RUN.captures_iter(text).count();
    let results: Vec<_> = GO_RESULT.captures_iter(text).collect();
    if runs == 0 || runs != results.len() {
        return None;
    }
    let passed = results.iter().filter(|c| &c[1] == "PASS").count() as u32;
    let failed = results.iter().filter(|c| &c[1] == "FAIL").count() as u32;
    let names = results
        .iter()
        .filter(|c| &c[1] == "FAIL")
        .map(|c| c[2].to_string())
        .collect();
    Some(TestRun {
        runner: "go".into(),
        passed,
        failed,
        total: passed + failed,
        failed_names: dedup(names, failed),
    })
}

// ---- vitest ----

static VITEST_TESTS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^\s+Tests  (.+) \((\d+)\)$").unwrap());
static VITEST_DURATION: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^\s+Duration  \S+.*$").unwrap());
static VITEST_FAIL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^ FAIL  (.+? > .+)$").unwrap());
static VITEST_CROSS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^\s+× (.+?)(?: \d+ms)?$").unwrap());

/// vitest ends its stdout on a block ("Test Files … / Tests 2 failed | 4 passed (6) / Start at
/// / Duration"); its failure details go to stderr, which comes after. The parts must add up to
/// the total, and anything after the block must be one of vitest's own `⎯⎯` sections.
fn vitest(text: &str, _long: bool) -> Option<TestRun> {
    let c = VITEST_TESTS.captures_iter(text).last()?;
    let at = c.get(0).unwrap().end();
    let duration = VITEST_DURATION.find_at(text, at)?;
    let after = text[duration.end()..].trim_start();
    if !(after.is_empty() || after.starts_with('⎯')) {
        return None;
    }
    let parts = counts(&c[1]);
    let total = n(&c[2]);
    let passed = count(&parts, &["passed"]);
    let failed = count(&parts, &["failed"]);
    if parts.iter().map(|(_, k)| k).sum::<u32>() != total || passed + failed == 0 {
        return None;
    }
    let mut names: Vec<String> = VITEST_FAIL
        .captures_iter(text)
        .map(|c| c[1].trim().to_string())
        .collect();
    if names.is_empty() {
        names = VITEST_CROSS
            .captures_iter(text)
            .map(|c| c[1].trim().to_string())
            .collect();
    }
    Some(TestRun {
        runner: "vitest".into(),
        passed,
        failed,
        total: passed + failed,
        failed_names: dedup(names, failed),
    })
}

// ---- jest ----

static JEST_TESTS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^Tests:\s+(.+), (\d+) total$").unwrap());
static JEST_TAIL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^\s*Snapshots:\s+.*\n\s*Time:\s+.*(?:\n\s*Ran all test suites.*|\n\s*Ran \d+ tests? .*)?\s*$").unwrap()
});
static JEST_FAIL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?m)^  ● (.+)$").unwrap());

/// jest (all on stderr) ends on "Tests: 2 failed, 1 skipped, 2 passed, 5 total / Snapshots /
/// Time / Ran all test suites." The parts must add up to the total.
fn jest(text: &str, _long: bool) -> Option<TestRun> {
    let c = JEST_TESTS.captures_iter(text).last()?;
    let rest = &text[c.get(0).unwrap().end()..];
    if !JEST_TAIL.is_match(rest.trim_start_matches('\n')) {
        return None;
    }
    let parts = counts(&c[1]);
    let total = n(&c[2]);
    let passed = count(&parts, &["passed"]);
    let failed = count(&parts, &["failed"]);
    if parts.iter().map(|(_, k)| k).sum::<u32>() != total || passed + failed == 0 {
        return None;
    }
    let names = JEST_FAIL
        .captures_iter(text)
        .map(|c| c[1].trim().to_string())
        .filter(|n| n != "Test suite failed to run")
        .collect();
    Some(TestRun {
        runner: "jest".into(),
        passed,
        failed,
        total: passed + failed,
        failed_names: dedup(names, failed),
    })
}

#[cfg(test)]
#[path = "test_run_tests.rs"]
mod tests;
