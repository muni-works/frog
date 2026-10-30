//! Logged out, `--providers` never reaches frog cloud, and `--catalog` lists only what frog
//! cloud's public `/v1/models` serves, asked without a key: FROG_BASE_URL points at a listener
//! that records every request and answers with a list.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn logged_out_the_catalog_is_frog_clouds_public_list() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    listener.set_nonblocking(true).unwrap();
    let requests = Arc::new(Mutex::new(Vec::<String>::new()));
    let stop = Arc::new(AtomicBool::new(false));
    let watcher = {
        let (requests, stop) = (requests.clone(), stop.clone());
        std::thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                if let Ok((mut sock, _)) = listener.accept() {
                    sock.set_nonblocking(false).unwrap();
                    let mut buf = [0u8; 8192];
                    let n = sock.read(&mut buf).unwrap_or(0);
                    requests
                        .lock()
                        .unwrap()
                        .push(String::from_utf8_lossy(&buf[..n]).into());
                    let body = r#"{"data":[
                        {"id":"tree","display_name":"Tree (GLM-5.3 Flash)","context_length":1048576,
                         "architecture":{"input_modalities":["text","image"]},
                         "supported_parameters":["tools","reasoning"]},
                        {"id":"bull","context_length":1048576}]}"#;
                    let _ = write!(
                        sock,
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                        body.len()
                    );
                }
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        })
    };

    let home = std::env::temp_dir().join(format!(
        "frog-logged-out-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    // Fresh caches for the public gateways, so the test doesn't reach the internet either.
    let catalog = home.join(".local/share/frog/catalog");
    std::fs::create_dir_all(&catalog).unwrap();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    for p in ["openrouter", "vercel"] {
        std::fs::write(
            catalog.join(format!("{p}.json")),
            format!(r#"{{"fetched":{now},"models":[]}}"#),
        )
        .unwrap();
    }

    let run = |args: &[&str]| {
        let mut c = Command::new(env!("CARGO_BIN_EXE_frog"));
        c.args(args)
            .env("HOME", &home)
            .env("FROG_BASE_URL", format!("http://{addr}/v1"))
            .env("FROG_KEYCHAIN", "off");
        for v in [
            "FROG_API_KEY",
            "TANG_CLOUD_API_KEY",
            "TANG_API_KEY",
            "ZEST_API_KEY",
            "OPENROUTER_API_KEY",
            "AI_GATEWAY_API_KEY",
            "VERCEL_AI_GATEWAY_API_KEY",
            "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY",
            "TANG_CLOUD_BASE_URL",
            "TANG_BASE_URL",
        ] {
            c.env_remove(v);
        }
        let out = c.output().unwrap();
        assert!(out.status.success(), "{:?}", out);
        String::from_utf8(out.stdout).unwrap()
    };

    let providers: serde_json::Value =
        serde_json::from_str(&run(&["--providers", "--json"])).unwrap();
    let cloud = providers
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["id"] == "cloud")
        .unwrap();
    assert_eq!(cloud["connected"], false);
    assert_eq!(cloud["pinned"], true);
    assert_eq!(cloud["rank"], 2);
    run(&["--providers"]);
    assert!(
        requests.lock().unwrap().is_empty(),
        "--providers contacted frog cloud while logged out"
    );
    let catalog: serde_json::Value = serde_json::from_str(&run(&["--catalog", "--json"])).unwrap();
    let cloud: Vec<&serde_json::Value> = catalog
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| m["provider"] == "cloud")
        .collect();
    // Only what frog cloud lists: nothing built in.
    let mut specs: Vec<&str> = cloud.iter().map(|m| m["spec"].as_str().unwrap()).collect();
    specs.sort();
    assert_eq!(specs, ["cloud/bull", "cloud/tree"]);
    let tree = cloud.iter().find(|m| m["spec"] == "cloud/tree").unwrap();
    assert_eq!(tree["name"], "Tree (GLM-5.3 Flash)");
    assert_eq!(tree["context"], 1_048_576);
    assert_eq!(tree["reasoning"], true);
    run(&["--catalog", "--refresh"]);
    let account = run(&["account"]);
    assert!(account.contains("not connected"), "{account}");

    stop.store(true, Ordering::Relaxed);
    watcher.join().unwrap();
    let _ = std::fs::remove_dir_all(&home);
    let requests = requests.lock().unwrap();
    assert!(!requests.is_empty());
    for r in requests.iter() {
        assert!(r.starts_with("GET /v1/models "), "{r}");
        assert!(
            !r.to_ascii_lowercase().contains("authorization:"),
            "a key went to frog cloud while logged out: {r}"
        );
    }
}
