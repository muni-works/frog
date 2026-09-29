//! Energy the Mac used while frog worked.
//!
//! The measure is the SMC's system power sensor (`PSTR`, watts drawn by the whole Mac from its
//! supply), sampled ten times a second and integrated. That covers the SoC, memory, SSD, display
//! and everything else; frog's share is what's left after subtracting the idle power measured
//! just before ([`Meter::idle_watts`]). The chip's own IOReport counters are kept alongside as a
//! breakdown (GPU, Neural Engine), but they aren't the headline: on macOS 27 the CPU and DRAM
//! counters stall at zero on every Apple silicon chip (vladkens/macmon#76), and they never saw
//! the rest of the machine anyway.
//!
//! Everything else running on the Mac lands in the same number. See frog.eco/energy.

use serde::{Deserialize, Serialize};

/// Joules per component over an interval.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Joules {
    pub cpu: f64,
    pub gpu: f64,
    pub ane: f64,
    pub dram: f64,
}

impl Joules {
    pub fn total(&self) -> f64 {
        self.cpu + self.gpu + self.ane + self.dram
    }

    pub fn wh(&self) -> f64 {
        self.total() / 3600.0
    }
}

impl std::ops::Sub for Joules {
    type Output = Joules;
    fn sub(self, o: Joules) -> Joules {
        Joules {
            cpu: self.cpu - o.cpu,
            gpu: self.gpu - o.gpu,
            ane: self.ane - o.ane,
            dram: self.dram - o.dram,
        }
    }
}

/// Which component a channel's energy belongs to, by its name. Clusters are counted once: the
/// per-core channels ("PCPU3") repeat what their cluster ("PCPU Energy"… or "CPU Energy") holds.
fn component(name: &str) -> Option<fn(&mut Joules) -> &mut f64> {
    if name == "CPU Energy" {
        Some(|j| &mut j.cpu)
    } else if name == "GPU Energy" || name == "GPU" {
        Some(|j| &mut j.gpu)
    } else if name.starts_with("ANE") {
        Some(|j| &mut j.ane)
    } else if name.starts_with("DRAM") {
        Some(|j| &mut j.dram)
    } else {
        None
    }
}

fn to_joules(value: i64, unit: &str) -> f64 {
    let v = value as f64;
    match unit {
        "mJ" => v / 1e3,
        "uJ" | "µJ" => v / 1e6,
        "nJ" => v / 1e9,
        _ => v,
    }
}

#[cfg(target_os = "macos")]
mod mac {
    use std::ffi::{CStr, CString, c_char, c_void};
    use std::ptr::null;

    type CFTypeRef = *const c_void;
    type CFDictionaryRef = *const c_void;
    type CFMutableDictionaryRef = *mut c_void;
    type CFStringRef = *const c_void;
    type CFArrayRef = *const c_void;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithCString(
            alloc: CFTypeRef,
            s: *const c_char,
            encoding: u32,
        ) -> CFStringRef;
        fn CFStringGetCString(s: CFStringRef, buf: *mut c_char, len: isize, encoding: u32) -> bool;
        fn CFDictionaryGetValue(d: CFDictionaryRef, key: CFTypeRef) -> CFTypeRef;
        fn CFDictionaryGetCount(d: CFDictionaryRef) -> isize;
        fn CFDictionaryCreateMutableCopy(
            alloc: CFTypeRef,
            cap: isize,
            d: CFDictionaryRef,
        ) -> CFMutableDictionaryRef;
        fn CFArrayGetCount(a: CFArrayRef) -> isize;
        fn CFArrayCreateMutable(
            alloc: CFTypeRef,
            cap: isize,
            callbacks: *const c_void,
        ) -> *mut c_void;
        fn CFArrayAppendValue(a: *mut c_void, v: CFTypeRef);
        fn CFDictionarySetValue(d: CFMutableDictionaryRef, key: CFTypeRef, value: CFTypeRef);
        static kCFTypeArrayCallBacks: c_void;
        fn CFArrayGetValueAtIndex(a: CFArrayRef, i: isize) -> CFTypeRef;
        fn CFRelease(t: CFTypeRef);
    }

    #[link(name = "IOReport", kind = "dylib")]
    unsafe extern "C" {
        fn IOReportCopyAllChannels(a: u64, b: u64) -> CFDictionaryRef;
        fn IOReportChannelGetGroup(item: CFDictionaryRef) -> CFStringRef;
        fn IOReportCreateSubscription(
            a: *const c_void,
            channels: CFMutableDictionaryRef,
            out: *mut CFMutableDictionaryRef,
            b: u64,
            c: CFTypeRef,
        ) -> *const c_void;
        fn IOReportCreateSamples(
            sub: *const c_void,
            channels: CFMutableDictionaryRef,
            a: CFTypeRef,
        ) -> CFDictionaryRef;
        fn IOReportCreateSamplesDelta(
            a: CFDictionaryRef,
            b: CFDictionaryRef,
            c: CFTypeRef,
        ) -> CFDictionaryRef;
        fn IOReportChannelGetChannelName(item: CFDictionaryRef) -> CFStringRef;
        fn IOReportChannelGetUnitLabel(item: CFDictionaryRef) -> CFStringRef;
        fn IOReportSimpleGetIntegerValue(item: CFDictionaryRef, i: i32) -> i64;
    }

    const UTF8: u32 = 0x0800_0100;

    fn cfstr(s: &str) -> CFStringRef {
        let c = CString::new(s).unwrap();
        unsafe { CFStringCreateWithCString(null(), c.as_ptr(), UTF8) }
    }

    fn string(s: CFStringRef) -> String {
        if s.is_null() {
            return String::new();
        }
        let mut buf = [0 as c_char; 128];
        if unsafe { CFStringGetCString(s, buf.as_mut_ptr(), buf.len() as isize, UTF8) } {
            unsafe { CStr::from_ptr(buf.as_ptr()) }
                .to_string_lossy()
                .into_owned()
        } else {
            String::new()
        }
    }

    /// A subscription to the Energy Model channels. Samples are cumulative counters.
    pub struct Source {
        sub: *const c_void,
        channels: CFMutableDictionaryRef,
    }

    // The subscription is only touched through &self calls that IOReport serializes itself.
    unsafe impl Send for Source {}
    unsafe impl Sync for Source {}

    pub struct Sample(CFDictionaryRef);
    unsafe impl Send for Sample {}
    unsafe impl Sync for Sample {}

    impl Drop for Sample {
        fn drop(&mut self) {
            unsafe { CFRelease(self.0) }
        }
    }

    impl Source {
        pub fn new() -> Option<Source> {
            unsafe {
                // Every channel, narrowed to the Energy Model group.
                let all = IOReportCopyAllChannels(0, 0);
                if all.is_null() {
                    return None;
                }
                let key = cfstr("IOReportChannels");
                let items = CFDictionaryGetValue(all, key);
                if items.is_null() {
                    CFRelease(key);
                    return None;
                }
                let n = CFArrayGetCount(items);
                let picked =
                    CFArrayCreateMutable(null(), n, &kCFTypeArrayCallBacks as *const c_void);
                for i in 0..n {
                    let item = CFArrayGetValueAtIndex(items, i);
                    if string(IOReportChannelGetGroup(item)) == "Energy Model" {
                        CFArrayAppendValue(picked, item);
                    }
                }
                let channels =
                    CFDictionaryCreateMutableCopy(null(), CFDictionaryGetCount(all), all);
                CFDictionarySetValue(channels, key, picked);
                CFRelease(key);
                let mut subbed: CFMutableDictionaryRef = std::ptr::null_mut();
                let sub = IOReportCreateSubscription(null(), channels, &mut subbed, 0, null());
                if sub.is_null() {
                    return None;
                }
                // `all` and `picked` stay alive for the subscription's lifetime (the process's).
                Some(Source { sub, channels })
            }
        }

        pub fn sample(&self) -> Option<Sample> {
            let s = unsafe { IOReportCreateSamples(self.sub, self.channels, null()) };
            (!s.is_null()).then_some(Sample(s))
        }

        /// (channel name, unit, value) for every channel, between two samples.
        pub fn delta(&self, a: &Sample, b: &Sample) -> Vec<(String, String, i64)> {
            let mut out = Vec::new();
            unsafe {
                let d = IOReportCreateSamplesDelta(a.0, b.0, null());
                if d.is_null() {
                    return out;
                }
                let key = cfstr("IOReportChannels");
                let items = CFDictionaryGetValue(d, key);
                CFRelease(key);
                if !items.is_null() {
                    for i in 0..CFArrayGetCount(items) {
                        let item = CFArrayGetValueAtIndex(items, i);
                        out.push((
                            string(IOReportChannelGetChannelName(item)),
                            string(IOReportChannelGetUnitLabel(item)).trim().to_string(),
                            IOReportSimpleGetIntegerValue(item, 0),
                        ));
                    }
                }
                CFRelease(d);
            }
            out
        }
    }
}

#[cfg(target_os = "macos")]
mod smc {
    //! The AppleSMC user client: key info (command 9), then the value (command 5), through
    //! `IOConnectCallStructMethod` selector 2 with the SMC's fixed request layout.
    use std::ffi::{CStr, CString, c_char, c_void};

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn mach_task_self() -> u32;
        fn IOServiceMatching(name: *const c_char) -> *mut c_void;
        fn IOServiceGetMatchingServices(port: u32, matching: *mut c_void, it: *mut u32) -> i32;
        fn IOIteratorNext(it: u32) -> u32;
        fn IORegistryEntryGetName(entry: u32, name: *mut c_char) -> i32;
        fn IOObjectRelease(obj: u32) -> i32;
        fn IOServiceOpen(device: u32, task: u32, kind: u32, conn: *mut u32) -> i32;
        fn IOConnectCallStructMethod(
            conn: u32,
            selector: u32,
            input: *const c_void,
            input_len: usize,
            output: *mut c_void,
            output_len: *mut usize,
        ) -> i32;
    }

    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct Version {
        major: u8,
        minor: u8,
        build: u8,
        reserved: u8,
        release: u16,
    }

    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct PowerLimits {
        version: u16,
        length: u16,
        cpu: u32,
        gpu: u32,
        mem: u32,
    }

    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct KeyInfo {
        size: u32,
        kind: u32,
        attributes: u8,
    }

    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct Request {
        key: u32,
        version: Version,
        limits: PowerLimits,
        info: KeyInfo,
        result: u8,
        status: u8,
        command: u8,
        data32: u32,
        bytes: [u8; 32],
    }

    const FLOAT: u32 = u32::from_be_bytes(*b"flt ");

    pub struct Smc {
        conn: u32,
    }

    impl Smc {
        pub fn open() -> Option<Smc> {
            let name = CString::new("AppleSMC").unwrap();
            let mut it = 0;
            unsafe {
                if IOServiceGetMatchingServices(0, IOServiceMatching(name.as_ptr()), &mut it) != 0 {
                    return None;
                }
                let mut conn = 0;
                loop {
                    let dev = IOIteratorNext(it);
                    if dev == 0 {
                        break;
                    }
                    let mut buf = [0 as c_char; 128];
                    IORegistryEntryGetName(dev, buf.as_mut_ptr());
                    if CStr::from_ptr(buf.as_ptr()).to_bytes() == b"AppleSMCKeysEndpoint" {
                        IOServiceOpen(dev, mach_task_self(), 0, &mut conn);
                    }
                    IOObjectRelease(dev);
                }
                IOObjectRelease(it);
                (conn != 0).then_some(Smc { conn })
            }
        }

        fn call(&self, req: &Request) -> Option<Request> {
            let mut out = Request::default();
            let mut len = size_of::<Request>();
            let rc = unsafe {
                IOConnectCallStructMethod(
                    self.conn,
                    2,
                    req as *const _ as *const c_void,
                    size_of::<Request>(),
                    &mut out as *mut _ as *mut c_void,
                    &mut len,
                )
            };
            (rc == 0 && out.result == 0).then_some(out)
        }

        /// A 4-byte float key, such as `PSTR` (system power, watts).
        pub fn float(&self, key: &[u8; 4]) -> Option<f32> {
            let key = u32::from_be_bytes(*key);
            let info = self
                .call(&Request {
                    key,
                    command: 9,
                    ..Default::default()
                })?
                .info;
            if info.size != 4 || info.kind != FLOAT {
                return None;
            }
            let out = self.call(&Request {
                key,
                info,
                command: 5,
                ..Default::default()
            })?;
            Some(f32::from_le_bytes(out.bytes[..4].try_into().ok()?))
        }
    }
}

/// Energy over an interval.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Reading {
    /// The whole Mac, from its supply, in joules.
    pub system_j: f64,
    /// The chip's own counters, where they work (see the module docs).
    pub soc: Joules,
    pub secs: f64,
}

impl Reading {
    pub fn system_wh(&self) -> f64 {
        self.system_j / 3600.0
    }

    /// What's left after `idle_w` for the interval: the extra energy the work cost.
    pub fn above_idle_wh(&self, idle_w: f64) -> f64 {
        ((self.system_j - idle_w * self.secs) / 3600.0).max(0.0)
    }
}

/// Integrates the system power sensor on its own thread, so a reading covers every moment of an
/// interval rather than its two ends. It also keeps the last minute of idle seconds (average
/// watts over each second nothing was `busy`), for a baseline without stopping to measure one.
#[cfg(target_os = "macos")]
struct Integrator {
    /// Joules since the meter started, as f64 bits.
    total: std::sync::Arc<std::sync::atomic::AtomicU64>,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    busy: std::sync::Arc<std::sync::atomic::AtomicBool>,
    idle: std::sync::Arc<std::sync::Mutex<std::collections::VecDeque<f64>>>,
}

/// How many idle seconds the baseline remembers.
#[cfg(target_os = "macos")]
const IDLE_WINDOW: usize = 60;

#[cfg(target_os = "macos")]
impl Integrator {
    fn start(smc: smc::Smc) -> Integrator {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
        let total = Arc::new(AtomicU64::new(0f64.to_bits()));
        let stop = Arc::new(AtomicBool::new(false));
        let busy = Arc::new(AtomicBool::new(false));
        let idle = Arc::new(std::sync::Mutex::new(std::collections::VecDeque::new()));
        let (t, s, b, q) = (total.clone(), stop.clone(), busy.clone(), idle.clone());
        std::thread::Builder::new()
            .name("frog-energy".into())
            .spawn(move || {
                let mut last = std::time::Instant::now();
                let mut last_w = smc.float(b"PSTR").map(f64::from).unwrap_or(0.0);
                // The current second: its joules, its start, and whether any of it was busy.
                let (mut sec_j, mut sec_at, mut sec_busy) = (0.0, last, false);
                while !s.load(Ordering::Relaxed) {
                    std::thread::sleep(std::time::Duration::from_millis(100));
                    let now = std::time::Instant::now();
                    let w = smc.float(b"PSTR").map(f64::from).unwrap_or(last_w);
                    // Trapezoid between samples.
                    let j = (w + last_w) / 2.0 * (now - last).as_secs_f64();
                    let prev = f64::from_bits(t.load(Ordering::Relaxed));
                    t.store((prev + j).to_bits(), Ordering::Relaxed);
                    (last, last_w) = (now, w);
                    sec_j += j;
                    sec_busy |= b.load(Ordering::Relaxed);
                    let span = (now - sec_at).as_secs_f64();
                    if span >= 1.0 {
                        if !sec_busy && let Ok(mut q) = q.lock() {
                            q.push_back(sec_j / span);
                            if q.len() > IDLE_WINDOW {
                                q.pop_front();
                            }
                        }
                        (sec_j, sec_at, sec_busy) = (0.0, now, b.load(Ordering::Relaxed));
                    }
                }
            })
            .ok();
        Integrator {
            total,
            stop,
            busy,
            idle,
        }
    }

    fn joules(&self) -> f64 {
        f64::from_bits(self.total.load(std::sync::atomic::Ordering::Relaxed))
    }
}

#[cfg(target_os = "macos")]
impl Drop for Integrator {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::Relaxed);
    }
}

/// Measures the Mac's energy. `None` where there's no system power sensor to read.
pub struct Meter {
    #[cfg(target_os = "macos")]
    power: Integrator,
    #[cfg(target_os = "macos")]
    soc: Option<mac::Source>,
}

/// A point in time to measure from.
pub struct Mark {
    joules: f64,
    #[cfg(target_os = "macos")]
    sample: Option<mac::Sample>,
    at: std::time::Instant,
}

impl Meter {
    pub fn new() -> Option<Meter> {
        #[cfg(target_os = "macos")]
        {
            let smc = smc::Smc::open()?;
            smc.float(b"PSTR")?;
            Some(Meter {
                power: Integrator::start(smc),
                soc: mac::Source::new(),
            })
        }
        #[cfg(not(target_os = "macos"))]
        None
    }

    pub fn mark(&self) -> Mark {
        #[cfg(target_os = "macos")]
        {
            Mark {
                joules: self.power.joules(),
                sample: self.soc.as_ref().and_then(|s| s.sample()),
                at: std::time::Instant::now(),
            }
        }
        #[cfg(not(target_os = "macos"))]
        Mark {
            joules: 0.0,
            at: std::time::Instant::now(),
        }
    }

    /// Energy from `from` until now.
    pub fn since(&self, from: &Mark) -> Reading {
        let mut r = Reading {
            secs: from.at.elapsed().as_secs_f64(),
            ..Default::default()
        };
        #[cfg(target_os = "macos")]
        {
            r.system_j = self.power.joules() - from.joules;
            if let (Some(src), Some(a)) = (&self.soc, &from.sample)
                && let Some(b) = src.sample()
            {
                for (name, unit, value) in src.delta(a, &b) {
                    if let Some(slot) = component(&name) {
                        *slot(&mut r.soc) += to_joules(value, &unit);
                    }
                }
            }
        }
        r
    }

    /// Every IOReport channel's energy from `from` until now, for checking what a chip reports.
    pub fn channels_since(&self, from: &Mark) -> Vec<(String, f64)> {
        #[cfg(target_os = "macos")]
        if let (Some(src), Some(a)) = (&self.soc, &from.sample)
            && let Some(b) = src.sample()
        {
            return src
                .delta(a, &b)
                .into_iter()
                .map(|(n, u, v)| (n, to_joules(v, &u)))
                .collect();
        }
        let _ = from;
        Vec::new()
    }

    /// Mark the Mac busy (a turn is running) or not; only seconds that weren't count as idle.
    pub fn set_busy(&self, busy: bool) {
        #[cfg(target_os = "macos")]
        self.power
            .busy
            .store(busy, std::sync::atomic::Ordering::Relaxed);
        #[cfg(not(target_os = "macos"))]
        let _ = busy;
    }

    /// Idle power from the last minute of seconds that weren't busy: their median, so a burst
    /// of other work doesn't move it much. An engine is often started just as a message is
    /// sent (opening a conversation), with no quiet seconds of its own yet; then it uses what
    /// the last engine on this Mac measured, saved in `idle_w`. `None` only before the first.
    pub fn idle_estimate(&self) -> Option<f64> {
        #[cfg(target_os = "macos")]
        {
            let seen: Vec<f64> = self.power.idle.lock().ok()?.iter().copied().collect();
            let saved = crate::config::data_dir().join("idle_w");
            if let Some(w) = median(seen.clone()) {
                let _ = std::fs::write(&saved, format!("{w:.3}"));
                return Some(w);
            }
            std::fs::read_to_string(&saved)
                .ok()
                .and_then(|t| t.trim().parse().ok())
                .or_else(|| {
                    (!seen.is_empty()).then(|| seen.iter().sum::<f64>() / seen.len() as f64)
                })
        }
        #[cfg(not(target_os = "macos"))]
        None
    }

    /// The Mac's average power over `secs` while frog asks nothing of it.
    pub async fn idle_watts(&self, secs: f64) -> f64 {
        let m = self.mark();
        tokio::time::sleep(std::time::Duration::from_secs_f64(secs)).await;
        let r = self.since(&m);
        if r.secs > 0.0 {
            r.system_j / r.secs
        } else {
            0.0
        }
    }
}

/// Energy a hosted model's data center spends on a request, estimated from its token counts.
/// Nobody publishes measured per-request energy for most models, so each gets the best
/// estimate we can source, per model:
///
/// - The reference is Epoch AI's estimate for GPT-4o on H100s, server and data center overhead
///   included ("How much energy does ChatGPT use?", Feb 2025): about 0.3 Wh for 500 output
///   tokens and about 2.2 Wh more for 10k input tokens, assuming ~100B active parameters.
/// - Inference work scales with *active* parameters (2 FLOPs per active parameter per token),
///   so an open-weight model with a published size scales that reference by its active count,
///   citing its model card.
/// - A closed model whose size isn't published (Claude, GPT, Gemini, Grok) keeps the frontier
///   reference as is, and says so.
///
/// It ignores prompt caching, which agent loops lean on, so treat it as the high end;
/// frog.eco/energy has the caveats.
pub mod cloud {
    /// The reference model's active parameters, in billions (Epoch AI's GPT-4o assumption).
    const REFERENCE_ACTIVE_B: f64 = 100.0;
    pub const WH_PER_INPUT_TOKEN: f64 = 2.2 / 10_000.0;
    pub const WH_PER_OUTPUT_TOKEN: f64 = 0.3 / 500.0;
    pub const BASIS: &str = "Epoch AI 2025, GPT-4o on H100";
    pub const REFERENCE_SOURCE: &str =
        "https://epoch.ai/gradient-updates/how-much-energy-does-chatgpt-use";

    /// How a model's estimate was made.
    #[derive(Clone, Debug, PartialEq)]
    pub struct Estimate {
        pub wh_per_input_token: f64,
        pub wh_per_output_token: f64,
        /// In words: "37B active parameters (DeepSeek-V3), scaled from Epoch AI's GPT-4o estimate".
        pub basis: String,
        /// Where the numbers come from.
        pub source: &'static str,
    }

    /// Open-weight models with published sizes: a fragment of their id, active parameters in
    /// billions, their name, and their model card.
    pub const OPEN: &[(&str, f64, &str, &str)] = &[
        (
            "qwen3-coder",
            35.0,
            "Qwen3-Coder 480B-A35B",
            "https://huggingface.co/Qwen/Qwen3-Coder-480B-A35B-Instruct",
        ),
        (
            "qwen3-235b",
            22.0,
            "Qwen3 235B-A22B",
            "https://huggingface.co/Qwen/Qwen3-235B-A22B",
        ),
        (
            "deepseek",
            37.0,
            "DeepSeek-V3",
            "https://huggingface.co/deepseek-ai/DeepSeek-V3",
        ),
        (
            "kimi-k2",
            32.0,
            "Kimi K2",
            "https://huggingface.co/moonshotai/Kimi-K2-Instruct",
        ),
        (
            "glm-4.5-air",
            12.0,
            "GLM-4.5-Air",
            "https://huggingface.co/zai-org/GLM-4.5-Air",
        ),
        (
            "glm-4.5",
            32.0,
            "GLM-4.5",
            "https://huggingface.co/zai-org/GLM-4.5",
        ),
        (
            "gpt-oss-120b",
            5.1,
            "gpt-oss-120b",
            "https://huggingface.co/openai/gpt-oss-120b",
        ),
        (
            "gpt-oss-20b",
            3.6,
            "gpt-oss-20b",
            "https://huggingface.co/openai/gpt-oss-20b",
        ),
        (
            "llama-4-maverick",
            17.0,
            "Llama 4 Maverick",
            "https://huggingface.co/meta-llama/Llama-4-Maverick-17B-128E-Instruct",
        ),
        (
            "mistral-large",
            123.0,
            "Mistral Large 2",
            "https://huggingface.co/mistralai/Mistral-Large-Instruct-2407",
        ),
    ];

    /// The estimate for a model spec (`vercel/anthropic/claude-opus-5.5`, `openrouter/qwen/qwen3-coder`).
    pub fn for_model(spec: &str) -> Estimate {
        let id = spec.to_ascii_lowercase();
        if let Some(&(_, active, name, source)) = OPEN.iter().find(|(frag, ..)| id.contains(frag)) {
            let k = active / REFERENCE_ACTIVE_B;
            return Estimate {
                wh_per_input_token: WH_PER_INPUT_TOKEN * k,
                wh_per_output_token: WH_PER_OUTPUT_TOKEN * k,
                basis: format!(
                    "{name}: {active}B active parameters, scaled from Epoch AI's GPT-4o estimate"
                ),
                source,
            };
        }
        Estimate {
            wh_per_input_token: WH_PER_INPUT_TOKEN,
            wh_per_output_token: WH_PER_OUTPUT_TOKEN,
            basis: "Size not published; assumes a frontier model like GPT-4o (Epoch AI)".into(),
            source: REFERENCE_SOURCE,
        }
    }

    impl Estimate {
        pub fn wh(&self, input_tokens: u64, output_tokens: u64) -> f64 {
            input_tokens as f64 * self.wh_per_input_token
                + output_tokens as f64 * self.wh_per_output_token
        }
    }

    /// Every model with its own estimate, then the frontier reference closed models use.
    pub fn table() -> Vec<(String, Option<f64>, Estimate)> {
        let mut rows: Vec<_> = OPEN
            .iter()
            .map(|&(frag, active, name, _)| (name.to_string(), Some(active), for_model(frag)))
            .collect();
        rows.push((
            "Closed models (Claude, GPT, Gemini, Grok)".into(),
            None,
            for_model(""),
        ));
        rows
    }

    /// The frontier reference, for callers without a model.
    pub fn estimate_wh(input_tokens: u64, output_tokens: u64) -> f64 {
        input_tokens as f64 * WH_PER_INPUT_TOKEN + output_tokens as f64 * WH_PER_OUTPUT_TOKEN
    }
}

/// The middle value, once there are at least three.
fn median(mut v: Vec<f64>) -> Option<f64> {
    if v.len() < 3 {
        return None;
    }
    v.sort_by(f64::total_cmp);
    let n = v.len();
    Some(if n % 2 == 1 {
        v[n / 2]
    } else {
        (v[n / 2 - 1] + v[n / 2]) / 2.0
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_is_the_median_of_enough_seconds() {
        assert_eq!(median(vec![12.0, 40.0]), None);
        assert_eq!(median(vec![12.0, 40.0, 13.0]), Some(13.0));
        assert_eq!(median(vec![12.0, 14.0, 13.0, 90.0]), Some(13.5));
    }

    #[test]
    fn above_idle_subtracts_the_baseline_and_never_goes_negative() {
        let r = Reading {
            system_j: 3600.0 * 2.0,
            secs: 100.0,
            ..Default::default()
        };
        assert!((r.above_idle_wh(36.0) - 1.0).abs() < 1e-9);
        assert_eq!(r.above_idle_wh(1000.0), 0.0);
    }

    #[test]
    fn channels_map_to_components_once() {
        assert!(component("CPU Energy").is_some());
        assert!(component("GPU Energy").is_some());
        assert!(component("ANE0").is_some());
        assert!(component("DRAM0").is_some());
        // Per-core and per-cluster channels repeat the cluster totals.
        assert!(component("PACC0_CPU3").is_none());
        assert!(component("EACC_CPU").is_none());
    }

    #[test]
    fn units_convert_to_joules() {
        assert_eq!(to_joules(1500, "mJ"), 1.5);
        assert_eq!(to_joules(2_000_000, "uJ"), 2.0);
        assert_eq!(to_joules(3_000_000_000, "nJ"), 3.0);
    }

    #[test]
    fn open_models_scale_by_active_parameters_and_closed_ones_say_so() {
        let ds = cloud::for_model("openrouter/deepseek/deepseek-chat-v3");
        assert!((ds.wh(0, 500) - 0.3 * 0.37).abs() < 1e-9);
        assert!(ds.source.contains("DeepSeek-V3"));
        // The Air before the full model: fragments are matched in order.
        assert!(
            cloud::for_model("openrouter/z-ai/glm-4.5-air")
                .basis
                .starts_with("GLM-4.5-Air")
        );
        let opus = cloud::for_model("vercel/anthropic/claude-opus-5.5-fast");
        assert!((opus.wh(10_000, 500) - 2.5).abs() < 1e-9);
        assert!(opus.basis.contains("not published"));
    }

    #[test]
    fn cloud_estimate_matches_its_source() {
        assert!((cloud::estimate_wh(0, 500) - 0.3).abs() < 1e-9);
        assert!((cloud::estimate_wh(10_000, 500) - 2.5).abs() < 1e-9);
    }
}
