//! A hung test fails the run instead of holding it: one held CI for 13 hours.
//!
//! Compiled into every test binary of frog and frog-engine (`cfg(test)` only, never into frog
//! itself; the frog crate's test targets include this file by path). A thread started before
//! `main` ends the process once the binary has run `FROG_TEST_TIMEOUT` seconds (default 300;
//! `0` turns it off). libtest names the culprit by then: it prints
//! `test <name> has been running for over 60 seconds` for every test past a minute.
//!
//! Per binary, not per test, because libtest has no per-test hook on stable. A whole binary
//! runs in about 30 s (frog-engine's lib tests, the longest), so the default is ten times that.

use std::time::Duration;

const DEFAULT_SECS: u64 = 300;

// Run `start` before `main`, the way the `ctor` crate does: a pointer in the platform's
// initializer section. Apple and Linux are where frog's tests run.
#[used]
#[cfg_attr(
    target_vendor = "apple",
    unsafe(link_section = "__DATA,__mod_init_func")
)]
#[cfg_attr(target_os = "linux", unsafe(link_section = ".init_array"))]
static START: extern "C" fn() = start;

extern "C" fn start() {
    let secs = std::env::var("FROG_TEST_TIMEOUT")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(DEFAULT_SECS);
    if secs == 0 {
        return;
    }
    let _ = std::thread::Builder::new()
        .name("frog-test-watchdog".into())
        .spawn(move || {
            std::thread::sleep(Duration::from_secs(secs));
            let bin = std::env::args().next().unwrap_or_default();
            eprintln!(
                "\nfrog test watchdog: {bin} still running after {secs}s, so a test is stuck. \
                 It's the one libtest reported above as \"has been running for over 60 seconds\" \
                 without finishing. Ending the run. (FROG_TEST_TIMEOUT=<seconds> changes the \
                 limit, 0 turns it off.)"
            );
            // Straight out: no atexit handlers or destructors that could wait on the stuck test.
            unsafe { libc::_exit(124) };
        });
}
