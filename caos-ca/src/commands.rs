use std::collections::HashSet;

use time::OffsetDateTime;
use zeroize::Zeroizing;

use crate::ca;
use crate::cli::{Cli, Command};
use crate::clock::{ensure_reasonable_clock, format_timestamp, now_utc, parse_timestamp};
use crate::config::Config;
use crate::crypto::prompt_new_root_passphrase;
use crate::error::{Error, Result};
use crate::store::{self, RuntimeLock};
use crate::util::normalize_serial;
use crate::verify;

pub fn run(cli: Cli) -> Result<()> {
    let config = Config::load(&cli.config)?;
    match cli.command {
        Command::Init => initialize(&config),
        Command::Issue { cn, sans } => issue(&config, &cn, &sans),
        Command::List => list(&config),
        Command::Revoke { serial } => revoke(&config, &serial),
        Command::Verify => run_verify(&config),
    }
}

fn initialize(config: &Config) -> Result<()> {
    let _lock = RuntimeLock::acquire(config, true)?;
    let now = now_utc()?;
    ensure_reasonable_clock(now)?;

    if store::state_exists(config) {
        return Err(Error::AlreadyInitialized(config.data_dir.clone()));
    }
    if !config.data_dir.is_dir() {
        return Err(Error::InvalidInput(format!(
            "CA data directory {} is not mounted or does not exist",
            config.data_dir.display()
        )));
    }

    let passphrase: Zeroizing<String> = prompt_new_root_passphrase()?;
    let outcome = ca::initialize(config, now, passphrase.as_str())?;

    println!("CA initialized.");
    println!("  root serial:          {}", outcome.root_serial);
    println!("  intermediate serial:  {}", outcome.intermediate_serial);
    println!("  root certificate:     {}", outcome.root_cert.display());
    println!(
        "  root private key:     {} (encrypted with the root passphrase)",
        outcome.root_key.display()
    );
    println!(
        "  intermediate cert:    {}",
        outcome.intermediate_cert.display()
    );
    println!(
        "  intermediate key:     {}",
        outcome.intermediate_key.display()
    );
    println!();
    println!("Keep the root passphrase and an offline copy of the encrypted root key separate.");
    Ok(())
}

fn issue(config: &Config, common_name: &str, sans: &[String]) -> Result<()> {
    let _lock = RuntimeLock::acquire(config, true)?;
    let now = now_utc()?;
    ensure_reasonable_clock(now)?;

    if !config.intermediate_key_path().is_file() {
        return Err(Error::NotInitialized(config.data_dir.clone()));
    }

    let outcome = ca::issue(config, now, common_name, sans)?;
    println!("Certificate issued.");
    println!("  serial:       {}", outcome.serial);
    println!("  expires:      {}", outcome.not_after);
    println!("  certificate:  {}", outcome.certificate.display());
    println!("  private key:  {}", outcome.private_key.display());
    Ok(())
}

fn list(config: &Config) -> Result<()> {
    let _lock = RuntimeLock::acquire(config, false)?;
    store::require_initialized(config)?;
    let metadata = store::load_metadata(config)?;
    let revocations = store::load_revocations(config)?;
    let revoked: HashSet<&str> = revocations
        .revoked
        .iter()
        .map(|record| record.serial.as_str())
        .collect();
    let now = now_utc()?;

    println!(
        "{:<32} {:<40} {:<26} STATUS",
        "SERIAL", "COMMON NAME", "EXPIRES (UTC)"
    );
    for certificate in &metadata.issued {
        let expiry = parse_timestamp(&certificate.not_after)?;
        let status = if revoked.contains(certificate.serial.as_str()) {
            "revoked"
        } else if expiry <= now {
            "expired"
        } else {
            "active"
        };
        println!(
            "{:<32} {:<40} {:<26} {}",
            certificate.serial,
            truncate_display(&certificate.common_name, 40),
            certificate.not_after,
            status
        );
    }
    if metadata.issued.is_empty() {
        println!("(no certificates issued)");
    }
    Ok(())
}

fn revoke(config: &Config, serial: &str) -> Result<()> {
    let _lock = RuntimeLock::acquire(config, true)?;
    let now = now_utc()?;
    ensure_reasonable_clock(now)?;
    let serial = normalize_serial(serial)?;
    ca::revoke(config, now, &serial, "unspecified")?;
    println!("Certificate revoked.");
    println!("  serial:      {serial}");
    println!("  revoked at:  {}", format_timestamp(now)?);
    Ok(())
}

fn run_verify(config: &Config) -> Result<()> {
    let _lock = RuntimeLock::acquire(config, false)?;
    let now: OffsetDateTime = now_utc()?;
    let report = verify::verify(config, now)?;
    println!("Verification successful.");
    println!("  system time:          {}", format_timestamp(now)?);
    println!("  root CA:              {}", report.root_subject);
    println!("  intermediate CA:      {}", report.intermediate_subject);
    println!("  issued certificates:  {}", report.issued_certificates);
    println!("  revoked certificates: {}", report.revoked_certificates);
    println!("  audit entries:        {}", report.audit_entries);
    println!(
        "  audit chain:          intact (audit file {})",
        config.audit_file().display()
    );
    Ok(())
}

fn truncate_display(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_string();
    }
    let mut result: String = value.chars().take(max_chars.saturating_sub(1)).collect();
    result.push('…');
    result
}
