//! Append-only JSON Lines audit log with a SHA-256 hash chain.
//!
//! The hash for an entry covers a canonical JSON object containing every
//! semantic field except `hash` itself.  Field order is fixed by the struct
//! layout, so independent verification does not depend on map iteration order.
//! The genesis `prev_hash` is 64 ASCII zeroes.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use time::{Duration, OffsetDateTime};

use crate::clock::{format_timestamp, parse_timestamp};
use crate::error::{Error, IoResultExt, Result};

pub const GENESIS_HASH: &str = "0000000000000000000000000000000000000000000000000000000000000000";
pub const TIME_SOURCE: &str = "system_clock";
const MAX_AUDIT_BYTES: u64 = 128 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuditRecord {
    pub prev_hash: String,
    pub hash: String,
    pub timestamp: String,
    pub action: String,
    pub serial: String,
    pub subject: String,
    pub time_source: String,
}

#[derive(Serialize)]
struct AuditHashInput<'a> {
    prev_hash: &'a str,
    timestamp: &'a str,
    action: &'a str,
    serial: &'a str,
    subject: &'a str,
    time_source: &'a str,
}

#[derive(Debug, Clone)]
pub struct AuditSummary {
    pub entries: usize,
    pub last_hash: String,
}

fn hash_fields(
    prev_hash: &str,
    timestamp: &str,
    action: &str,
    serial: &str,
    subject: &str,
) -> Result<String> {
    let input = AuditHashInput {
        prev_hash,
        timestamp,
        action,
        serial,
        subject,
        time_source: TIME_SOURCE,
    };
    let bytes = serde_json::to_vec(&input)
        .map_err(|error| Error::Audit(format!("cannot encode hash input: {error}")))?;
    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    Ok(hex::encode(hasher.finalize()))
}

fn read_all_records(path: &Path) -> Result<Vec<AuditRecord>> {
    if !path.exists() {
        return Err(Error::Audit(format!(
            "audit log {} is missing",
            path.display()
        )));
    }
    let metadata = fs::metadata(path).at(path)?;
    if !metadata.is_file() {
        return Err(Error::Audit(format!(
            "audit log {} is not a regular file",
            path.display()
        )));
    }
    if metadata.len() > MAX_AUDIT_BYTES {
        return Err(Error::Audit(format!(
            "audit log {} exceeds the {} byte safety limit",
            path.display(),
            MAX_AUDIT_BYTES
        )));
    }

    let mut file = File::open(path).at(path)?;
    let mut contents = String::new();
    file.read_to_string(&mut contents).at(path)?;
    if contents.is_empty() {
        return Ok(Vec::new());
    }
    if !contents.ends_with('\n') {
        return Err(Error::Audit(
            "audit log does not end with a complete newline-terminated record".into(),
        ));
    }

    let mut records = Vec::new();
    for (index, line) in contents.lines().enumerate() {
        if line.is_empty() {
            return Err(Error::Audit(format!(
                "audit log contains an empty line at line {}",
                index + 1
            )));
        }
        let record: AuditRecord = serde_json::from_str(line).map_err(|error| {
            Error::Audit(format!("cannot parse audit line {}: {error}", index + 1))
        })?;
        records.push(record);
    }
    Ok(records)
}

/// Verify the whole chain and check timestamps.  Returns a summary containing
/// the current chain tip.  An empty-but-existing audit log is invalid because
/// initialization always records an `init` entry.
pub fn verify_chain(path: &Path, now: OffsetDateTime) -> Result<AuditSummary> {
    let records = read_all_records(path)?;
    if records.is_empty() {
        return Err(Error::Audit(
            "audit log is empty; expected at least the initialization entry".into(),
        ));
    }

    let mut previous_hash = GENESIS_HASH.to_string();
    let mut previous_timestamp: Option<OffsetDateTime> = None;
    let future_limit = now
        .checked_add(Duration::minutes(5))
        .ok_or_else(|| Error::Audit("timestamp overflow".into()))?;

    for (index, record) in records.iter().enumerate() {
        let line = index + 1;
        if record.prev_hash != previous_hash {
            return Err(Error::Audit(format!(
                "hash-chain break at line {line}: prev_hash does not match the previous record"
            )));
        }
        if record.time_source != TIME_SOURCE {
            return Err(Error::Audit(format!(
                "line {line} has unexpected time_source {:?}",
                record.time_source
            )));
        }
        if record.action.is_empty() || record.serial.is_empty() || record.subject.is_empty() {
            return Err(Error::Audit(format!(
                "line {line} has an empty action, serial or subject"
            )));
        }
        if record.hash.len() != 64
            || !record
                .hash
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            return Err(Error::Audit(format!(
                "line {line} has a malformed SHA-256 hash"
            )));
        }
        let expected = hash_fields(
            &record.prev_hash,
            &record.timestamp,
            &record.action,
            &record.serial,
            &record.subject,
        )?;
        if expected != record.hash {
            return Err(Error::Audit(format!(
                "hash mismatch at line {line}: recorded hash does not cover the record"
            )));
        }
        let timestamp = parse_timestamp(&record.timestamp)?;
        if timestamp > future_limit {
            return Err(Error::Audit(format!(
                "line {line} is timestamped in the future ({})",
                record.timestamp
            )));
        }
        if let Some(previous) = previous_timestamp {
            if timestamp < previous {
                return Err(Error::Audit(format!(
                    "timestamp goes backwards at line {line}"
                )));
            }
        }
        previous_timestamp = Some(timestamp);
        previous_hash.clone_from(&record.hash);
    }

    Ok(AuditSummary {
        entries: records.len(),
        last_hash: previous_hash,
    })
}

/// Create a brand-new audit log.  Fails if the file already exists.
pub fn initialize(path: &Path) -> Result<()> {
    let mut options = OpenOptions::new();
    options
        .write(true)
        .append(true)
        .create_new(true)
        .mode(0o600);
    let file = options.open(path).at(path)?;
    file.sync_all().at(path)?;
    Ok(())
}

/// Append one record.  The caller must hold the exclusive CA lock and must
/// have verified that the CA data directory is initialized.
///
/// The file is opened with `O_APPEND` every time; no code path ever truncates
/// or rewrites the log.
pub fn append(
    path: &Path,
    action: &str,
    serial: &str,
    subject: &str,
    now: OffsetDateTime,
) -> Result<AuditRecord> {
    // A fresh audit file is created empty by `initialize`, then the genesis
    // record is appended.  An empty file is therefore valid only here, while
    // `verify_chain` (used by the verify command) rejects it.
    let metadata = fs::metadata(path).at(path)?;
    if !metadata.is_file() {
        return Err(Error::Audit(format!(
            "audit log {} is not a regular file",
            path.display()
        )));
    }
    let summary = if metadata.len() == 0 {
        AuditSummary {
            entries: 0,
            last_hash: GENESIS_HASH.to_string(),
        }
    } else {
        verify_chain(path, now)?
    };
    let timestamp = format_timestamp(now)?;
    let hash = hash_fields(&summary.last_hash, &timestamp, action, serial, subject)?;
    let record = AuditRecord {
        prev_hash: summary.last_hash,
        hash,
        timestamp,
        action: action.to_string(),
        serial: serial.to_string(),
        subject: subject.to_string(),
        time_source: TIME_SOURCE.to_string(),
    };
    let mut line = serde_json::to_vec(&record)
        .map_err(|error| Error::Audit(format!("cannot serialize audit entry: {error}")))?;
    line.push(b'\n');

    let mut options = OpenOptions::new();
    options.append(true).mode(0o600);
    let mut file = options.open(path).at(path)?;
    file.write_all(&line).at(path)?;
    file.sync_data().at(path)?;
    Ok(record)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::TempDir;
    use time::OffsetDateTime;

    use super::{append, hash_fields, initialize, verify_chain, GENESIS_HASH};

    #[test]
    fn hash_chain_roundtrip_and_tamper_detection() {
        let temp = TempDir::new().expect("tempdir");
        let path = temp.path().join("audit.jsonl");
        initialize(&path).expect("initialize");
        let now = OffsetDateTime::now_utc();
        append(&path, "init", &"11".repeat(16), "CN=CAOS Root", now).expect("append init");
        append(
            &path,
            "issue",
            &"22".repeat(16),
            "CN=host.example",
            now + time::Duration::seconds(1),
        )
        .expect("append issue");
        let summary = verify_chain(&path, now + time::Duration::seconds(2)).expect("valid chain");
        assert_eq!(summary.entries, 2);

        let contents = fs::read_to_string(&path).expect("read audit");
        let tampered = contents.replacen("issue", "revoke", 1);
        fs::write(&path, tampered).expect("write tampered audit");
        assert!(verify_chain(&path, now + time::Duration::seconds(3)).is_err());
    }

    #[test]
    fn genesis_chain_starts_at_zero_hash() {
        let now = OffsetDateTime::now_utc();
        let timestamp = crate::clock::format_timestamp(now).expect("format");
        let hash = hash_fields(GENESIS_HASH, &timestamp, "init", "abc", "CN=CAOS").expect("hash");
        assert_eq!(hash.len(), 64);
    }
}
