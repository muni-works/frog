fn main() {
    esp_idf_svc::sys::link_patches();
    esp_idf_svc::log::EspLogger::initialize_default();
    log::info!("frog puck: hello");
    loop {
        log::info!("tick");
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
}
