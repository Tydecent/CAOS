mod audit;
mod ca;
mod cli;
mod clock;
mod commands;
mod config;
mod crypto;
mod error;
mod secure;
mod store;
mod util;
mod verify;

use clap::Parser;

fn main() {
    if let Err(error) = secure::harden_process() {
        eprintln!("caos-ca: refusing to run without process hardening: {error}");
        std::process::exit(1);
    }

    let cli = cli::Cli::parse();
    if let Err(error) = commands::run(cli) {
        eprintln!("caos-ca: error: {error}");
        std::process::exit(1);
    }
}
