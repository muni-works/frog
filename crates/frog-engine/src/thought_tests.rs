//! Runs `docs/design/transcript/thoughts.json`, the definition of the thought line, and checks
//! the streaming form against the pure one.

use super::*;
use serde_json::Value;

const CASES: &str = include_str!("../../../docs/design/transcript/thoughts.json");

fn cases() -> Value {
    serde_json::from_str(CASES).expect("thoughts.json parses")
}

fn expect(v: &Value) -> Option<String> {
    v.as_str().map(str::to_string)
}

/// Every `lines` case: the line for the reasoning, or for each prefix after each chunk.
#[test]
fn line_cases() {
    let all = cases();
    let lines = all["lines"].as_array().unwrap();
    assert!(
        lines.len() >= 60,
        "at least sixty line cases ({})",
        lines.len()
    );
    let mut failed = Vec::new();
    for c in lines {
        let name = c["name"].as_str().unwrap();
        if let Some(r) = c["reasoning"].as_str() {
            let got = line(r);
            if got != expect(&c["expect"]) {
                failed.push(format!("{name}: got {got:?}, want {:?}", c["expect"]));
            }
        } else {
            let mut so_far = String::new();
            let chunks = c["chunks"].as_array().expect("reasoning or chunks");
            let wants = c["expect"].as_array().expect("one expect per chunk");
            assert_eq!(chunks.len(), wants.len(), "{name}: one expect per chunk");
            for (i, (ch, want)) in chunks.iter().zip(wants).enumerate() {
                so_far.push_str(ch.as_str().unwrap());
                let got = line(&so_far);
                if got != expect(want) {
                    failed.push(format!(
                        "{name} (after chunk {i}): got {got:?}, want {want:?}"
                    ));
                }
            }
        }
    }
    assert!(
        failed.is_empty(),
        "{} failing:\n{}",
        failed.len(),
        failed.join("\n")
    );
}

/// The reasoning of a `lines` case, whole.
fn reasoning(c: &Value) -> String {
    match c["reasoning"].as_str() {
        Some(r) => r.to_string(),
        None => c["chunks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c.as_str().unwrap())
            .collect(),
    }
}

/// Fed one character at a time with no throttling (each a full interval apart), the stream
/// shows exactly the pure line for every prefix of every case.
#[test]
fn stream_matches_pure_function_on_every_prefix() {
    for c in cases()["lines"].as_array().unwrap() {
        let r = reasoning(c);
        let mut t = Thoughts::default();
        let mut showing: Option<String> = None;
        for (k, (i, ch)) in r.char_indices().enumerate() {
            if let Some(l) = t.push(ch.encode_utf8(&mut [0; 4]), k as u64 * INTERVAL_MS) {
                showing = Some(l);
            }
            let prefix = &r[..i + ch.len_utf8()];
            assert_eq!(showing, line(prefix), "{}: prefix {prefix:?}", c["name"]);
        }
    }
}

/// Every `streams` case: the thought each chunk carries (absent = no change), and the lines the
/// completed item lists.
#[test]
fn stream_cases() {
    let all = cases();
    let streams = all["streams"].as_array().unwrap();
    assert!(!streams.is_empty());
    for c in streams {
        let name = c["name"].as_str().unwrap();
        let mut t = Thoughts::default();
        for (i, e) in c["events"].as_array().unwrap().iter().enumerate() {
            let got = t.push(e["chunk"].as_str().unwrap(), e["at"].as_u64().unwrap());
            assert_eq!(got, expect(&e["thought"]), "{name}: event {i}");
        }
        let text = c["final"].as_str().unwrap_or(t.text()).to_string();
        let shown: Vec<ShownThought> = serde_json::from_value(c["shown"].clone()).unwrap();
        assert_eq!(t.shown(&text), shown, "{name}: shown");
    }
}

/// The offsets really are UTF-16 indices: slicing the item's text by them (as JavaScript would)
/// gives back each shown line's paragraph.
#[test]
fn offsets_are_utf16() {
    let text =
        "Das Über-Flag 🚀 bleibt aus, sagt die Doku.\n\nThe second paragraph is shown later.\n\n";
    let mut t = Thoughts::default();
    t.push(text, 0);
    let mut t2 = Thoughts::default();
    t2.push("Das Über-Flag 🚀 bleibt aus, sagt die Doku.\n\n", 0);
    t2.push("The second paragraph is shown later.\n\n", INTERVAL_MS);
    let shown = t2.shown(t2.text());
    let units: Vec<u16> = text.encode_utf16().collect();
    let para =
        |s: &ShownThought| String::from_utf16(&units[s.start as usize..s.end as usize]).unwrap();
    assert_eq!(
        para(&shown[0]),
        "Das Über-Flag 🚀 bleibt aus, sagt die Doku."
    );
    assert_eq!(para(&shown[1]), "The second paragraph is shown later.");
    // Byte offsets would have put the second paragraph three units later.
    assert_eq!(shown[1].start, 45);
}

/// Old completed reasoning items, with no `thoughts`, still decode; new ones round-trip.
#[test]
fn reasoning_item_wire() {
    use crate::protocol::Item;
    let old: Item = serde_json::from_str(r#"{"type":"reasoning","text":"hi"}"#).unwrap();
    assert_eq!(
        old,
        Item::Reasoning {
            text: "hi".into(),
            thoughts: Vec::new(),
            think_ms: None,
        }
    );
    let new = Item::Reasoning {
        text: "The parser is slow.\n\n".into(),
        thoughts: vec![ShownThought {
            text: "The parser is slow".into(),
            start: 0,
            end: 19,
            ms: 0,
        }],
        think_ms: Some(1500),
    };
    let json = serde_json::to_string(&new).unwrap();
    assert_eq!(
        json,
        r#"{"type":"reasoning","text":"The parser is slow.\n\n","thoughts":[{"text":"The parser is slow","start":0,"end":19,"ms":0}],"think_ms":1500}"#
    );
    assert_eq!(serde_json::from_str::<Item>(&json).unwrap(), new);
    // A bare item serializes exactly as before.
    assert_eq!(
        serde_json::to_string(&old).unwrap(),
        r#"{"type":"reasoning","text":"hi"}"#
    );
}

/// A reasoning delta without a thought is the old shape; with one, it carries it.
#[test]
fn reasoning_delta_wire() {
    use crate::protocol::Delta;
    let old: Delta = serde_json::from_str(r#"{"type":"reasoning","text":"a"}"#).unwrap();
    assert_eq!(
        old,
        Delta::Reasoning {
            text: "a".into(),
            thought: None
        }
    );
    assert_eq!(
        serde_json::to_string(&old).unwrap(),
        r#"{"type":"reasoning","text":"a"}"#
    );
    let new = Delta::Reasoning {
        text: "\n".into(),
        thought: Some("Check the tests first".into()),
    };
    let json = serde_json::to_string(&new).unwrap();
    assert_eq!(
        json,
        r#"{"type":"reasoning","text":"\n","thought":"Check the tests first"}"#
    );
    assert_eq!(serde_json::from_str::<Delta>(&json).unwrap(), new);
}

/// Real reasoning, streamed through the thought line, measured per model. Reads Cam's session
/// logs locally and prints statistics only; never run in CI and never commit its output.
/// `FROG_THOUGHT_LOGS=~/.local/share/frog/sessions cargo test -p frog-engine thought::tests::measure -- --ignored --nocapture`
/// (add `FROG_THOUGHT_SAMPLES=1` to also print sampled lines, for reading locally).
#[test]
#[ignore]
fn measure() {
    super::measure::run();
}
