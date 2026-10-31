use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;

use sha2::{Digest, Sha256};

use crate::error::{Error, IoResultExt, Result};

pub const PUBLIC_FILE_MODE: u32 = 0o644;
pub const PRIVATE_FILE_MODE: u32 = 0o600;

/// Hash bytes with SHA-256 and return lowercase hex.
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

/// Hash a regular file without loading it all into memory at once.
pub fn sha256_file(path: &Path) -> Result<(String, u64)> {
    let mut file = File::open(path).at(path)?;
    let mut hasher = Sha256::new();
    let mut size = 0_u64;
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).at(path)?;
        if read == 0 {
            break;
        }
        size = size.saturating_add(read as u64);
        hasher.update(&buffer[..read]);
    }
    Ok((hex::encode(hasher.finalize()), size))
}

/// Read a public file while enforcing a size cap.
pub fn read_public_file(path: &Path, max_bytes: u64) -> Result<Vec<u8>> {
    let metadata = fs::metadata(path).at(path)?;
    if !metadata.is_file() {
        return Err(Error::InvalidInput(format!(
            "{} is not a regular file",
            path.display()
        )));
    }
    if metadata.len() > max_bytes {
        return Err(Error::InvalidInput(format!(
            "{} exceeds the {} byte limit",
            path.display(),
            max_bytes
        )));
    }
    fs::read(path).at(path)
}

/// Write a new file with explicit permissions.  Existing files are not
/// replaced, which makes accidental key overwrites fail loudly.
pub fn write_new_file(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true).mode(mode);
    let mut file = options.open(path).at(path)?;
    file.write_all(bytes).at(path)?;
    file.sync_all().at(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).at(path)?;
    Ok(())
}

/// Atomically replace a metadata file using write-then-rename in the same
/// directory.  Callers are responsible for holding the CA lock.
pub fn write_atomic_file(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    let parent = path.parent().ok_or_else(|| {
        Error::InvalidInput(format!("{} has no parent directory", path.display()))
    })?;
    let file_name = path
        .file_name()
        .ok_or_else(|| Error::InvalidInput(format!("{} has no file name", path.display())))?;
    let mut temporary_name = std::ffi::OsString::from(".");
    temporary_name.push(file_name);
    temporary_name.push(format!(".tmp.{}", std::process::id()));
    let temporary_path = parent.join(temporary_name);

    match fs::remove_file(&temporary_path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(Error::io(&temporary_path, error)),
    }

    let result = (|| {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true).mode(mode);
        let mut file = options.open(&temporary_path).at(&temporary_path)?;
        file.write_all(bytes).at(&temporary_path)?;
        file.sync_all().at(&temporary_path)?;
        fs::set_permissions(&temporary_path, fs::Permissions::from_mode(mode))
            .at(&temporary_path)?;
        fs::rename(&temporary_path, path).at(path)?;
        // Make the rename durable as well.
        File::open(parent).at(parent)?.sync_all().at(parent)?;
        Ok(())
    })();

    if result.is_err() {
        let _ = fs::remove_file(&temporary_path);
    }
    result
}

/// Enforce private permissions on an existing file.
pub fn require_private_mode(path: &Path) -> Result<()> {
    let metadata = fs::metadata(path).at(path)?;
    let mode = metadata.permissions().mode() & 0o777;
    if mode & 0o077 != 0 {
        return Err(Error::Integrity(format!(
            "{} has insecure mode {:04o}; expected no group/other access",
            path.display(),
            mode
        )));
    }
    Ok(())
}

/// Normalize a user-supplied certificate serial.
///
/// A serial is treated as an unsigned integer: optional `0x`, colons and
/// whitespace are removed, lowercase hex is required, and the value is
/// left-padded to the 32 hex digits used for generated 128-bit serials.
/// Values wider than 128 bits are rejected.
pub fn normalize_serial(input: &str) -> Result<String> {
    let trimmed = input.trim();
    let without_prefix = trimmed
        .strip_prefix("0x")
        .or_else(|| trimmed.strip_prefix("0X"))
        .unwrap_or(trimmed);
    let mut normalized = String::new();
    for character in without_prefix.chars() {
        if character == ':' || character.is_ascii_whitespace() {
            continue;
        }
        if character.is_ascii_hexdigit() {
            normalized.push(character.to_ascii_lowercase());
        } else {
            return Err(Error::InvalidInput(
                "serial must contain only hexadecimal digits, colons or spaces".into(),
            ));
        }
    }
    if normalized.is_empty() {
        return Err(Error::InvalidInput("serial must not be empty".into()));
    }
    if normalized.len() > 32 {
        return Err(Error::InvalidInput("serial is wider than 128 bits".into()));
    }
    Ok(format!("{normalized:0>32}"))
}

/// Canonical 32-hex-digit representation of a serial value.
pub fn serial_hex(bytes: &[u8]) -> String {
    let mut first_nonzero = 0;
    while first_nonzero + 1 < bytes.len() && bytes[first_nonzero] == 0 {
        first_nonzero += 1;
    }
    let significant = &bytes[first_nonzero..];
    // Certificate serials are limited to 128 bits by construction.  Keep the
    // low-order 16 bytes if a caller passes something larger.
    let significant = if significant.len() > 16 {
        &significant[significant.len() - 16..]
    } else {
        significant
    };
    format!("{:0>32}", hex::encode(significant))
}

/// Create a directory if needed and force 0700 permissions on it.
pub fn ensure_private_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path).at(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).at(path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{normalize_serial, serial_hex};

    #[test]
    fn serial_normalization_is_canonical() {
        assert_eq!(
            normalize_serial("0xAB:CD").expect("valid serial"),
            format!("{:0>32}", "abcd")
        );
        assert_eq!(serial_hex(&[0xab, 0xcd]), format!("{:0>32}", "abcd"));
        assert_eq!(serial_hex(&[0xff; 16]), "ff".repeat(16));
    }

    #[test]
    fn rejects_oversized_or_invalid_serials() {
        assert!(normalize_serial("zz").is_err());
        assert!(normalize_serial("11".repeat(17).as_str()).is_err());
        assert!(normalize_serial("").is_err());
    }
}
