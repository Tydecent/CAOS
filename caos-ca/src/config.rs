use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::{Error, IoResultExt, Result};

pub const DEFAULT_CONFIG_PATH: &str = "/etc/caos-ca/config.toml";
const MAX_CONFIG_BYTES: u64 = 64 * 1024;

/// On-disk configuration contract shared with the Buildroot image.
///
/// `runtime_dir` is optional so the shipped read-only configuration only needs
/// the two values named by the deployment contract.  The default is the tmpfs
/// path used by the image.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub ca_name: String,
    pub data_dir: PathBuf,
    #[serde(default = "default_runtime_dir")]
    pub runtime_dir: PathBuf,
}

fn default_runtime_dir() -> PathBuf {
    PathBuf::from("/run/caos-ca")
}

impl Config {
    pub fn load(path: &Path) -> Result<Self> {
        let metadata = fs::metadata(path).at(path)?;
        if !metadata.is_file() {
            return Err(Error::Config(format!(
                "{} is not a regular file",
                path.display()
            )));
        }
        if metadata.len() > MAX_CONFIG_BYTES {
            return Err(Error::Config(format!(
                "{} is larger than {} bytes",
                path.display(),
                MAX_CONFIG_BYTES
            )));
        }
        let contents = fs::read_to_string(path).at(path)?;
        let config: Self = toml::from_str(&contents).map_err(|source| Error::ConfigSyntax {
            path: path.to_path_buf(),
            source,
        })?;
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> Result<()> {
        if self.ca_name.trim().is_empty() {
            return Err(Error::Config("ca_name must not be empty".into()));
        }
        if self.ca_name.chars().any(char::is_control) {
            return Err(Error::Config(
                "ca_name must not contain control characters".into(),
            ));
        }
        if self.ca_name.len() > 160 {
            return Err(Error::Config("ca_name is too long".into()));
        }
        validate_absolute_dir("data_dir", &self.data_dir)?;
        validate_absolute_dir("runtime_dir", &self.runtime_dir)?;
        Ok(())
    }

    pub fn db_dir(&self) -> PathBuf {
        self.data_dir.join("db")
    }

    pub fn issued_dir(&self) -> PathBuf {
        self.db_dir().join("issued")
    }

    pub fn audit_dir(&self) -> PathBuf {
        self.data_dir.join("audit")
    }

    pub fn audit_file(&self) -> PathBuf {
        self.audit_dir().join("audit.jsonl")
    }

    pub fn root_cert_path(&self) -> PathBuf {
        self.db_dir().join("root-ca.crt")
    }

    pub fn root_key_path(&self) -> PathBuf {
        self.db_dir().join("root-ca.key.enc")
    }

    pub fn intermediate_cert_path(&self) -> PathBuf {
        self.db_dir().join("intermediate-ca.crt")
    }

    pub fn intermediate_key_path(&self) -> PathBuf {
        self.db_dir().join("intermediate-ca.key")
    }

    pub fn metadata_path(&self) -> PathBuf {
        self.db_dir().join("metadata.json")
    }

    pub fn integrity_path(&self) -> PathBuf {
        self.db_dir().join("integrity.json")
    }

    pub fn revocations_path(&self) -> PathBuf {
        self.db_dir().join("revoked.json")
    }

    pub fn lock_path(&self) -> PathBuf {
        self.runtime_dir.join("caos-ca.lock")
    }
}

fn validate_absolute_dir(name: &str, value: &Path) -> Result<()> {
    if !value.is_absolute() {
        return Err(Error::Config(format!("{name} must be an absolute path")));
    }
    if value.as_os_str().is_empty() {
        return Err(Error::Config(format!("{name} must not be empty")));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::Config;

    #[test]
    fn defaults_runtime_dir() {
        let config: Config = toml::from_str(
            r#"
ca_name = "CAOS Test CA"
data_dir = "/tmp/caos-data"
"#,
        )
        .expect("valid config");
        assert_eq!(config.runtime_dir, Path::new("/run/caos-ca"));
        assert_eq!(config.db_dir(), Path::new("/tmp/caos-data/db"));
    }

    #[test]
    fn rejects_relative_data_dir() {
        let config: Config = toml::from_str(
            r#"
ca_name = "CAOS Test CA"
data_dir = "relative"
"#,
        )
        .expect("syntax is valid");
        let err = config.validate().expect_err("relative path is rejected");
        assert!(err.to_string().contains("absolute"));
    }
}
