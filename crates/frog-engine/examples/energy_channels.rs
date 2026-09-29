//! Prints what the energy meter sees over three seconds: system power from the SMC, and every
//! IOReport Energy Model channel that moved. `cargo run -p frog-engine --example energy_channels`
#[tokio::main]
async fn main() {
    let Some(m) = frog_engine::energy::Meter::new() else {
        eprintln!("no system power sensor on this machine");
        return;
    };
    let mark = m.mark();
    tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    for (name, j) in m.channels_since(&mark) {
        if j != 0.0 {
            println!("{name:<24} {j:>10.4} J");
        }
    }
    let r = m.since(&mark);
    println!(
        "\n{:.2}s · system {:.2} W ({:.4} Wh) · soc {:?}",
        r.secs,
        r.system_j / r.secs,
        r.system_wh(),
        r.soc
    );
}
