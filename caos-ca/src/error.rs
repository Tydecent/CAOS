use std::io;
use std::path::{Path, PathBuf};

use thiserror::Error;

pub type Result<T> = std::result::Result<T, Error>;

/// All failures that can be surfaced to the operator.
///
/// Error messages deliberately never include private-key material, passphrases
/// or derived keys.
#[derive(Debug, Error)]
pub enum Error {
    #[error("I/O error for {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },

    #[error("configuration error in {path}: {source}")]
    ConfigSyntax {
        path: PathBuf,
        #[source]
        source: toml::de::Error,
    },

    #[error("invalid configuration: {0}")]
    Config(String),

    #[error("{context} in {path}: {source}")]
    Json {
        context: &'static str,
        path: PathBuf,
        #[source]
        source: serde_json::Error,
    },

    #[error("system clock error: {0}")]
    Clock(String),

    #[error("the CA is already initialized in {0}")]
    AlreadyInitialized(PathBuf),

    #[error("the CA is not initialized in {0}; run `caos-ca init` first")]
    NotInitialized(PathBuf),

    #[error("invalid input: {0}")]
    InvalidInput(String),

    #[error("passphrase error: {0}")]
    Passphrase(String),

    #[error("cryptographic operation failed: {0}")]
    Crypto(String),

    #[error("certificate operation failed: {0}")]
    Certificate(#[from] rcgen::Error),

    #[error("could not lock secret memory with mlock(2): {0}")]
    MemoryLock(io::Error),

    #[error("process hardening failed: {0}")]
    Hardening(String),

    #[error("integrity verification failed: {0}")]
    Integrity(String),

    #[error("audit-log verification failed: {0}")]
    Audit(String),

    #[error("certificate verification failed: {0}")]
    Verification(String),

    #[error("time processing failed: {0}")]
    Time(String),
}

impl Error {
    pub(crate) fn io(path: impl AsRef<Path>, source: io::Error) -> Self {
        Self::Io {
            path: path.as_ref().to_path_buf(),
            source,
        }
    }

    pub(crate) fn json(
        path: impl AsRef<Path>,
        context: &'static str,
        source: serde_json::Error,
    ) -> Self {
        Self::Json {
            context,
            path: path.as_ref().to_path_buf(),
            source,
        }
    }
}

/// Adds the file path to an `io::Result` error.
pub(crate) trait IoResultExt<T> {
    fn at(self, path: impl AsRef<Path>) -> Result<T>;
}

impl<T> IoResultExt<T> for io::Result<T> {
    fn at(self, path: impl AsRef<Path>) -> Result<T> {
        self.map_err(|error| Error::io(path, error))
    }
}
