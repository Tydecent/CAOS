use std::collections::{BTreeMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use fs2::FileExt;
use serde::{Deserialize, Serialize};

use crate::config::Config;
use crate::error::{Error, IoResultExt, Result};
use crate::secure::SecretVec;
use crate::util::{
    ensure_private_dir, read_public_file, sha256_file, write_atomic_file, PRIVATE_FILE_MODE,
};

pub const FORMAT_VERSION: u32 = 1;
const MAX_CA_FILE_BYTES: u64 = 1024 * 1024;
const MAX_SECRET_BYTES: u64 = 64 * 1024;
pub const MAX_CERT_BYTES: u64 = 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaRecord {
    pub serial: String,
    pub subject: String,
    pub not_before: String,
    pub not_after: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IssuedCertificate {
    pub serial: String,
    pub common_name: String,
    pub subject: String,
    pub san: Vec<String>,
    pub not_before: String,
    pub not_after: String,
    pub issued_at: String,
    pub certificate_sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaMetadata {
    pub format_version: u32,
    pub ca_name: String,
    pub initialized_at: String,
    pub root: CaRecord,
    pub intermediate: CaRecord,
    pub issued: Vec<IssuedCertificate>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RevokedCertificate {
    pub serial: String,
    pub revoked_at: String,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RevocationList {
    pub format_version: u32,
    pub revoked: Vec<RevokedCertificate>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileFingerprint {
    pub sha256: String,
    pub size: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntegrityManifest {
    pub format_version: u32,
    pub ca_name: String,
    pub created_at: String,
    pub files: BTreeMap<String, FileFingerprint>,
}

#[derive(Debug)]
pub struct RuntimeLock {
    _file: File,
}

impl RuntimeLock {
    pub fn acquire(config: &Config, exclusive: bool) -> Result<Self> {
        // The image creates this directory and gives it to the caos user.  For
        // developer runs it is convenient to create it when permissions allow.
        if !config.runtime_dir.exists() {
            fs::create_dir_all(&config.runtime_dir).at(&config.runtime_dir)?;
            fs::set_permissions(&config.runtime_dir, fs::Permissions::from_mode(0o700))
                .at(&config.runtime_dir)?;
        }
        let lock_path = config.lock_path();
        let mut options = OpenOptions::new();
        options
            .read(true)
            .write(true)
            .create(true)
            .mode(PRIVATE_FILE_MODE);
        let file = options.open(&lock_path).at(&lock_path)?;
        if exclusive {
            FileExt::lock_exclusive(&file).at(&lock_path)?;
        } else {
            FileExt::lock_shared(&file).at(&lock_path)?;
        }
        Ok(Self { _file: file })
    }
}

pub fn state_exists(config: &Config) -> bool {
    config.root_cert_path().exists()
        || config.root_key_path().exists()
        || config.intermediate_cert_path().exists()
        || config.intermediate_key_path().exists()
        || config.metadata_path().exists()
        || config.audit_file().exists()
}

pub fn require_initialized(config: &Config) -> Result<()> {
    if !config.metadata_path().is_file()
        || !config.root_cert_path().is_file()
        || !config.intermediate_cert_path().is_file()
    {
        return Err(Error::NotInitialized(config.data_dir.clone()));
    }
    Ok(())
}

/// Create the directory tree and reject a data directory containing unrelated
/// pre-existing entries.  This prevents an accidental re-initialization from
/// scattering CA material among old files.
pub fn prepare_data_directories(config: &Config) -> Result<()> {
    let data_metadata = fs::metadata(&config.data_dir).at(&config.data_dir)?;
    if !data_metadata.is_dir() {
        return Err(Error::InvalidInput(format!(
            "{} is not a directory; mount the CA data filesystem first",
            config.data_dir.display()
        )));
    }
    if state_exists(config) {
        return Err(Error::AlreadyInitialized(config.data_dir.clone()));
    }

    let db = config.db_dir();
    if db.exists() {
        let mut entries = fs::read_dir(&db).at(&db)?;
        if entries.next().is_some() {
            return Err(Error::AlreadyInitialized(config.data_dir.clone()));
        }
    }
    ensure_private_dir(&db)?;
    ensure_private_dir(&config.issued_dir())?;
    ensure_private_dir(&config.audit_dir())?;
    Ok(())
}

pub fn load_metadata(config: &Config) -> Result<CaMetadata> {
    let path = config.metadata_path();
    let bytes = read_public_file(&path, MAX_CA_FILE_BYTES)?;
    let metadata: CaMetadata = serde_json::from_slice(&bytes)
        .map_err(|source| Error::json(&path, "cannot parse CA metadata", source))?;
    if metadata.format_version != FORMAT_VERSION {
        return Err(Error::Integrity(format!(
            "unsupported CA metadata format version {}",
            metadata.format_version
        )));
    }
    if metadata.ca_name != config.ca_name {
        return Err(Error::Integrity(
            "CA metadata name does not match the configuration".into(),
        ));
    }
    Ok(metadata)
}

pub fn save_metadata(config: &Config, metadata: &CaMetadata) -> Result<()> {
    let path = config.metadata_path();
    let bytes = serde_json::to_vec_pretty(metadata)
        .map_err(|source| Error::json(&path, "cannot serialize CA metadata", source))?;
    write_atomic_file(&path, &bytes, PRIVATE_FILE_MODE)
}

pub fn load_revocations(config: &Config) -> Result<RevocationList> {
    let path = config.revocations_path();
    let bytes = read_public_file(&path, MAX_CA_FILE_BYTES)?;
    let revocations: RevocationList = serde_json::from_slice(&bytes)
        .map_err(|source| Error::json(&path, "cannot parse revocation list", source))?;
    if revocations.format_version != FORMAT_VERSION {
        return Err(Error::Integrity(format!(
            "unsupported revocation-list format version {}",
            revocations.format_version
        )));
    }
    Ok(revocations)
}

pub fn save_revocations(config: &Config, revocations: &RevocationList) -> Result<()> {
    let path = config.revocations_path();
    let bytes = serde_json::to_vec_pretty(revocations)
        .map_err(|source| Error::json(&path, "cannot serialize revocation list", source))?;
    write_atomic_file(&path, &bytes, PRIVATE_FILE_MODE)
}

pub fn load_integrity(config: &Config) -> Result<IntegrityManifest> {
    let path = config.integrity_path();
    let bytes = read_public_file(&path, MAX_CA_FILE_BYTES)?;
    let manifest: IntegrityManifest = serde_json::from_slice(&bytes)
        .map_err(|source| Error::json(&path, "cannot parse integrity manifest", source))?;
    if manifest.format_version != FORMAT_VERSION {
        return Err(Error::Integrity(format!(
            "unsupported integrity manifest format version {}",
            manifest.format_version
        )));
    }
    if manifest.ca_name != config.ca_name {
        return Err(Error::Integrity(
            "integrity manifest name does not match the configuration".into(),
        ));
    }
    Ok(manifest)
}

pub fn save_integrity(config: &Config, manifest: &IntegrityManifest) -> Result<()> {
    let path = config.integrity_path();
    let bytes = serde_json::to_vec_pretty(manifest)
        .map_err(|source| Error::json(&path, "cannot serialize integrity manifest", source))?;
    write_atomic_file(&path, &bytes, PRIVATE_FILE_MODE)
}

/// Hash the static CA files and persist the result.
pub fn refresh_integrity(
    config: &Config,
    ca_name: &str,
    created_at: &str,
) -> Result<IntegrityManifest> {
    let mut files = BTreeMap::new();
    for name in [
        "root-ca.crt",
        "root-ca.key.enc",
        "intermediate-ca.crt",
        "intermediate-ca.key",
        "metadata.json",
        "revoked.json",
    ] {
        let path = config.db_dir().join(name);
        let (sha256, size) = sha256_file(&path)?;
        files.insert(name.to_string(), FileFingerprint { sha256, size });
    }
    let manifest = IntegrityManifest {
        format_version: FORMAT_VERSION,
        ca_name: ca_name.to_string(),
        created_at: created_at.to_string(),
        files,
    };
    save_integrity(config, &manifest)?;
    Ok(manifest)
}

pub fn check_integrity(config: &Config) -> Result<IntegrityManifest> {
    let manifest = load_integrity(config)?;
    for (name, expected) in &manifest.files {
        // The manifest is generated by us; nevertheless reject path
        // components so a corrupted manifest cannot read outside db/.
        if name.contains('/') || name.contains('\\') || name == "integrity.json" {
            return Err(Error::Integrity(format!(
                "integrity manifest contains an invalid file name {name:?}"
            )));
        }
        let path = config.db_dir().join(name);
        let (actual_hash, actual_size) = sha256_file(&path)?;
        if actual_hash != expected.sha256 || actual_size != expected.size {
            return Err(Error::Integrity(format!(
                "{} does not match the signed-in-time integrity manifest",
                path.display()
            )));
        }
    }
    for required in [
        "root-ca.crt",
        "root-ca.key.enc",
        "intermediate-ca.crt",
        "intermediate-ca.key",
        "metadata.json",
        "revoked.json",
    ] {
        if !manifest.files.contains_key(required) {
            return Err(Error::Integrity(format!(
                "integrity manifest is missing required entry {required}"
            )));
        }
    }
    Ok(manifest)
}

pub fn read_public_cert(config: &Config, path: &Path) -> Result<Vec<u8>> {
    if path != config.root_cert_path().as_path()
        && path != config.intermediate_cert_path().as_path()
        && !path.starts_with(config.issued_dir())
    {
        return Err(Error::InvalidInput(
            "certificate path escapes the CA data directory".into(),
        ));
    }
    read_public_file(path, MAX_CERT_BYTES)
}

/// Read private-key material straight into a page-locked buffer.
pub fn read_secret_file(path: &Path) -> Result<SecretVec> {
    let metadata = fs::metadata(path).at(path)?;
    if !metadata.is_file() {
        return Err(Error::InvalidInput(format!(
            "{} is not a regular file",
            path.display()
        )));
    }
    if metadata.len() == 0 || metadata.len() > MAX_SECRET_BYTES {
        return Err(Error::InvalidInput(format!(
            "{} has an unsafe size",
            path.display()
        )));
    }
    let mut secret = SecretVec::zeroed(metadata.len() as usize)?;
    let mut file = File::open(path).at(path)?;
    file.read_exact(secret.as_mut_slice()).at(path)?;
    Ok(secret)
}

pub fn issued_cert_path(config: &Config, serial: &str) -> PathBuf {
    config.issued_dir().join(format!("{serial}.crt"))
}

pub fn issued_key_path(config: &Config, serial: &str) -> PathBuf {
    config.issued_dir().join(format!("{serial}.key"))
}

pub fn all_known_serials(metadata: &CaMetadata, revocations: &RevocationList) -> HashSet<String> {
    let mut serials = HashSet::new();
    serials.insert(metadata.root.serial.clone());
    serials.insert(metadata.intermediate.serial.clone());
    for issued in &metadata.issued {
        serials.insert(issued.serial.clone());
    }
    for revoked in &revocations.revoked {
        serials.insert(revoked.serial.clone());
    }
    serials
}
