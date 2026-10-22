//! Logged out, `--providers` and `--catalog` never reach frog cloud: FROG_BASE_URL points at a
//! listener that fails the test if anything connects.

use std::net::TcpListener;
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn providers_and_catalog_make_no_cloud_requests_logged_out() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    listener.set_nonblocking(true).unwrap();
    let hit = Arc::new(AtomicBool::new(false));
    let stop = Arc::new(AtomicBool::new(false));
    let watcher = {
        let (hit, stop) = (hit.clone(), stop.clone());
        std::thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                if listener.accept().is_ok() {
                    hit.store(true, Ordering::Relaxed);
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
    let catalog: serde_json::Value = serde_json::from_str(&run(&["--catalog", "--json"])).unwrap();
    assert!(
        catalog
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["spec"] == "cloud/qwen3-coder-next" && m["context"] == 131_072)
    );
    assert!(
        catalog
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["spec"] == "cloud/qwen3-8b" && m["context"] == 16_384)
    );
    assert!(
        catalog
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["spec"] == "cloud/qwen3-vl-8b" && m["context"] == 16_384 && m["inputs"].as_array().is_some())
    );
    run(&["--catalog", "--refresh"]);
    let account = run(&["account"]);
    assert!(account.contains("not connected"), "{account}");

    stop.store(true, Ordering::Relaxed);
    watcher.join().unwrap();
    let _ = std::fs::remove_dir_all(&home);
    assert!(
        !hit.load(Ordering::Relaxed),
        "frog cloud was contacted while logged out"
    );
}
