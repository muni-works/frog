//! The wire protocol as JSON Schema, generated from the Rust types ([`crate::protocol`]).
//!
//! Rust is the source of truth for the protocol; clients (Swift, TypeScript) derive their
//! types from the schema artifact (`schema/frog-engine-1.json`, committed and covered by a
//! golden-file test) rather than from hand-copied twins that drift. Run
//! `cargo test -p frog-engine schema` to regenerate and check it.

use crate::protocol::{Envelope, Op};
use schemars::generate::SchemaSettings;
use schemars::SchemaGenerator;
use serde_json::{Map, Value};

/// The artifact's path relative to the crate root, and its schema dialect.
pub const ARTIFACT: &str = "schema/frog-engine-1.json";
const DIALECT: &str = "https://json-schema.org/draft/2020-12/schema";

/// One document with every wire type: `$defs` keyed by type name, and a top-level `anyOf`
/// over `Op` (client → engine) and `Envelope` (engine → client), the two roots of the wire.
pub fn protocol_schema() -> Value {
    let mut settings = SchemaSettings::draft2020_12();
    settings.definitions_path = "/$defs".into();
    let mut generator = SchemaGenerator::new(settings);
    generator.subschema_for::<Op>();
    generator.subschema_for::<Envelope>();
    let mut defs: Map<String, Value> = generator
        .take_definitions(true)
        .into_iter()
        .map(|(k, v)| (k, Value::from(v)))
        .collect();

    // schemars can't lower `#[serde(flatten)]` over an internally tagged enum: the derived
    // Envelope schema loses `seq`/`session`/`created` because each flattened event variant
    // becomes its own oneOf branch. Splice the envelope fields into every variant by hand;
    // the wire shape this describes is what `envelope_round_trips_flat` asserts in
    // protocol.rs.
    let event = defs.get("Event").cloned().expect("Event schema in $defs");
    defs.insert("Envelope".into(), envelope_schema(&event));

    let mut root = Map::new();
    root.insert("$schema".into(), Value::String(DIALECT.into()));
    root.insert("title".into(), Value::String("frog engine protocol".into()));
    root.insert(
        "anyOf".into(),
        serde_json::json!([
            {"$ref": "#/$defs/Op"},
            {"$ref": "#/$defs/Envelope"},
        ]),
    );
    root.insert("$defs".into(), Value::Object(defs));
    Value::Object(root)
}

/// `Envelope` as it serializes: `seq`, `session`, `created` beside the flattened
/// [`crate::protocol::Event`]'s fields, with `event` as the tag.
fn envelope_schema(event: &Value) -> Value {
    let variants = event
        .get("oneOf")
        .and_then(Value::as_array)
        .cloned()
        .expect("Event schema is a tagged enum");
    let merged: Vec<Value> = variants
        .into_iter()
        .map(|mut variant| {
            let obj = variant.as_object_mut().expect("variant is an object");
            let props = obj.entry("properties".to_string()).or_insert(Value::Object(Map::new()));
            let props = props.as_object_mut().expect("variant properties");
            props.insert(
                "seq".into(),
                serde_json::json!({"type": "integer", "minimum": 0, "format": "uint64"}),
            );
            props.insert("session".into(), serde_json::json!({"type": "string"}));
            props.insert(
                "created".into(),
                serde_json::json!({"type": "integer", "format": "int64"}),
            );
            let req = obj.entry("required".to_string()).or_insert(Value::Array(Vec::new()));
            let req = req.as_array_mut().expect("variant required");
            req.push(Value::String("seq".into()));
            req.push(Value::String("session".into()));
            req.push(Value::String("created".into()));
            variant
        })
        .collect();
    serde_json::json!({
        "description": "Wrapper for every event.",
        "oneOf": merged,
    })
}

/// The artifact's text: keys sorted, so it doesn't depend on whether serde_json's
/// `preserve_order` feature got unified in (it does when frog builds alongside, via acp).
pub fn artifact_json() -> serde_json::Result<String> {
    Ok(serde_json::to_string_pretty(&sorted(protocol_schema()))? + "\n")
}

fn sorted(value: Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut entries: Vec<_> = map.into_iter().collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            Value::Object(entries.into_iter().map(|(k, v)| (k, sorted(v))).collect())
        }
        Value::Array(items) => Value::Array(items.into_iter().map(sorted).collect()),
        other => other,
    }
}

/// Write the artifact.
pub fn write_artifact() -> std::io::Result<()> {
    let json = artifact_json()?;
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(ARTIFACT);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(path, json)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every type reachable from `Op` and `Envelope` made it into `$defs` — a lost derive
    /// (a new variant over a type without `JsonSchema`) shows up as a `$ref` to a missing
    /// definition, which the golden diff also catches.
    #[test]
    fn defs_are_complete() {
        let schema = protocol_schema();
        let defs = schema["$defs"].as_object().unwrap();
        for name in ["Op", "Envelope", "Event", "Item", "TurnUsage", "Status"] {
            assert!(defs.contains_key(name), "missing $defs/{name}");
        }
    }

    /// The envelope fields survive the flatten workaround: every Envelope variant carries
    /// seq, session and created, and every Op variant carries the `op` tag.
    #[test]
    fn envelope_fields_are_spliced_into_every_variant() {
        let schema = protocol_schema();
        for variant in schema["$defs"]["Envelope"]["oneOf"].as_array().unwrap() {
            let props = variant["properties"].as_object().unwrap();
            for field in ["seq", "session", "created", "event"] {
                assert!(props.contains_key(field), "Envelope variant missing {field}");
            }
        }
        for variant in schema["$defs"]["Op"]["oneOf"].as_array().unwrap() {
            assert!(
                variant["properties"].as_object().unwrap().contains_key("op"),
                "Op variant missing the op tag"
            );
        }
    }

    /// Regenerate and assert no drift against the committed artifact. After a deliberate
    /// protocol change, commit the file this test writes.
    #[test]
    fn artifact_matches_types() {
        write_artifact().unwrap();
        let fresh = artifact_json().unwrap();
        let committed = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(ARTIFACT),
        )
        .unwrap();
        assert_eq!(fresh, committed);
    }

    /// The schema must accept the real wire: samples drawn from protocol.rs's own
    /// round-trip tests validate against the generated document.
    #[test]
    fn samples_validate() {
        let schema = protocol_schema();
        for sample in [
            serde_json::json!({"op":"submit","text":"hi"}),
            serde_json::json!({"op":"permission","id":"p1","decision":"allow"}),
            serde_json::json!({"op":"permission","id":"p1","decision":"deny","note":"not that"}),
            serde_json::json!({"op":"answer","id":"q1","choices":["Truncate"]}),
            serde_json::json!({"seq":3,"session":"s","created":1,"event":"item_delta","id":"i","delta":{"type":"text","text":"hi"}}),
            serde_json::json!({"seq":1,"session":"s","created":1,"event":"turn_started","turn":1,"input":"x"}),
        ] {
            let errors = validate(&schema, &sample);
            assert!(errors.is_empty(), "{sample} failed: {errors:?}");
        }
        // And rejects an unknown tag.
        assert!(
            !validate(&schema, &serde_json::json!({"op":"teleport"})).is_empty(),
            "unknown op must not validate"
        );
    }

    /// Minimal draft 2020-12 validation for the shapes this document uses ($ref, anyOf,
    /// oneOf, const, required, type, minimum). Not a general validator; enough to keep the
    /// golden file honest.
    fn validate(schema: &Value, value: &Value) -> Vec<String> {
        let mut errors = Vec::new();
        validate_node(schema, schema, value, "$", &mut errors);
        errors
    }

    fn resolve(schema: &Value, node: &Value) -> Value {
        let Some(reference) = node.get("$ref").and_then(Value::as_str) else {
            return node.clone();
        };
        let mut resolved = schema.clone();
        for part in reference.trim_start_matches("#/").split('/') {
            resolved = resolved.get(part).cloned().unwrap_or(Value::Null);
        }
        resolved
    }

    fn validate_node(
        schema: &Value,
        node: &Value,
        value: &Value,
        at: &str,
        errors: &mut Vec<String>,
    ) {
        let node = resolve(schema, node);
        if let Some(branches) = node
            .get("anyOf")
            .or_else(|| node.get("oneOf"))
            .and_then(Value::as_array)
        {
            let matched = branches.iter().any(|branch| {
                let mut e = Vec::new();
                validate_node(schema, branch, value, at, &mut e);
                e.is_empty()
            });
            if !matched {
                errors.push(format!("{at}: matched no branch"));
            }
            return;
        }
        if let Some(const_value) = node.get("const") {
            if const_value != value {
                errors.push(format!("{at}: expected {const_value}"));
            }
        }
        if let Some(expected) = node.get("type").and_then(Value::as_str) {
            let ok = match expected {
                "string" => value.is_string(),
                "integer" => value.is_i64() || value.is_u64(),
                "number" => value.is_number(),
                "boolean" => value.is_boolean(),
                "array" => value.is_array(),
                "object" => value.is_object(),
                "null" => value.is_null(),
                _ => true,
            };
            if !ok {
                errors.push(format!("{at}: expected {expected}"));
            }
        }
        if let Some(minimum) = node.get("minimum").and_then(Value::as_f64) {
            if value.as_f64().is_some_and(|n| n < minimum) {
                errors.push(format!("{at}: below minimum"));
            }
        }
        if let Some(required) = node.get("required").and_then(Value::as_array) {
            for field in required {
                let field = field.as_str().unwrap();
                if value.get(field).is_none() {
                    errors.push(format!("{at}: missing {field}"));
                }
            }
        }
        if let Some(properties) = node.get("properties").and_then(Value::as_object) {
            for (field, subschema) in properties {
                if let Some(field_value) = value.get(field) {
                    validate_node(
                        schema,
                        subschema,
                        field_value,
                        &format!("{at}.{field}"),
                        errors,
                    );
                }
            }
        }
        if let Some(items) = node.get("items") {
            if let Some(values) = value.as_array() {
                for (i, item) in values.iter().enumerate() {
                    validate_node(schema, items, item, &format!("{at}[{i}]"), errors);
                }
            }
        }
    }
}
