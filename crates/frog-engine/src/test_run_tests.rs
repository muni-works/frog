//! Runs every recorded output in `tests/fixtures/test_runs/` against `expect.json`.

use super::*;
use serde_json::Value;
use std::path::Path;

fn dir() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/test_runs")
}

#[test]
fn fixtures() {
    let expect: Value =
        serde_json::from_str(&std::fs::read_to_string(dir().join("expect.json")).unwrap()).unwrap();
    let expect = expect["expect"].as_object().unwrap();
    let mut failed = Vec::new();
    let mut files = 0;
    for entry in std::fs::read_dir(dir()).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_none_or(|x| x != "txt") {
            continue;
        }
        files += 1;
        let name = path.file_stem().unwrap().to_str().unwrap().to_string();
        let want: Option<TestRun> = serde_json::from_value(
            expect
                .get(&name)
                .unwrap_or_else(|| panic!("{name} has no expectation"))
                .clone(),
        )
        .unwrap();
        let got = parse(&std::fs::read_to_string(&path).unwrap());
        if got != want {
            failed.push(format!("{name}:\n  got  {got:?}\n  want {want:?}"));
        }
    }
    assert_eq!(files, expect.len(), "one expectation per fixture");
    assert!(
        failed.is_empty(),
        "{} failing:\n{}",
        failed.len(),
        failed.join("\n")
    );
}

/// Every runner's recordings are here, passing and failing.
#[test]
fn every_runner_is_covered() {
    for runner in ["cargo", "pytest", "go", "vitest", "jest"] {
        for kind in ["pass", "fail"] {
            assert!(
                std::fs::read_dir(dir()).unwrap().any(|e| e
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with(&format!("{runner}_{kind}"))),
                "no {runner}_{kind} fixture"
            );
        }
    }
}

/// The wire: absent on an old command item, and a round trip when present.
#[test]
fn tool_call_wire() {
    use crate::protocol::Item;
    let old = r#"{"type":"tool_call","name":"Bash","arg":"ls","input":{},"outcome":"ok","output":"a","display":null}"#;
    let item: Item = serde_json::from_str(old).unwrap();
    assert!(matches!(&item, Item::ToolCall { tests: None, .. }));
    assert_eq!(serde_json::to_string(&item).unwrap(), old);
    let run = TestRun {
        runner: "cargo".into(),
        passed: 10,
        failed: 1,
        total: 11,
        failed_names: vec!["tests::adds".into()],
    };
    let json = serde_json::to_string(&run).unwrap();
    assert_eq!(
        json,
        r#"{"runner":"cargo","passed":10,"failed":1,"total":11,"failed_names":["tests::adds"]}"#
    );
    assert_eq!(serde_json::from_str::<TestRun>(&json).unwrap(), run);
}
