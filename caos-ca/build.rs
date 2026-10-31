use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    let seconds = match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_secs(),
        Err(error) => panic!("build machine clock is before the Unix epoch: {error}"),
    };

    println!("cargo:rustc-env=CAOS_BUILD_UNIX_TIME={seconds}");
}
