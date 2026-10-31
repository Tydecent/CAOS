//! Process-level hardening and locked secret buffers.
//!
//! The tokens and key material handled by this program are small.  A dedicated
//! buffer that is `mlock(2)`-ed and explicitly wiped on drop is therefore cheap
//! and makes the lifetime of private-key material obvious.

use std::fmt;
use std::io;

use zeroize::Zeroize;

use crate::error::{Error, Result};

/// Disables core dumps and ptrace-style inspection of this process, then makes
/// all subsequently created files private by default.
///
/// `PR_SET_DUMPABLE=0` makes the process non-dumpable, which also disables
/// `/proc/<pid>/mem` access by unprivileged processes.  `RLIMIT_CORE=0` is a
/// second, independent barrier against core files.
pub fn harden_process() -> Result<()> {
    // SAFETY: umask has no pointer arguments and only affects this process.
    unsafe {
        libc::umask(0o077);
    }

    let mut limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: `limit` points to a valid, fully initialized rlimit structure.
    let get_result = unsafe { libc::getrlimit(libc::RLIMIT_CORE, &mut limit) };
    if get_result != 0 {
        return Err(Error::Hardening(format!(
            "getrlimit(RLIMIT_CORE) failed: {}",
            io::Error::last_os_error()
        )));
    }
    limit.rlim_cur = 0;
    limit.rlim_max = 0;
    // SAFETY: `limit` points to a valid rlimit structure owned by this stack.
    let set_result = unsafe { libc::setrlimit(libc::RLIMIT_CORE, &limit) };
    if set_result != 0 {
        return Err(Error::Hardening(format!(
            "setrlimit(RLIMIT_CORE, 0) failed: {}",
            io::Error::last_os_error()
        )));
    }

    // SAFETY: prctl(PR_SET_DUMPABLE) takes scalar arguments only.
    let prctl_result = unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) };
    if prctl_result != 0 {
        return Err(Error::Hardening(format!(
            "prctl(PR_SET_DUMPABLE, 0) failed: {}",
            io::Error::last_os_error()
        )));
    }

    Ok(())
}

/// A fixed-size, page-locked heap buffer for sensitive bytes.
///
/// The vector is never exposed for resizing, so the address passed to `mlock`
/// stays valid for the lifetime of the value.  `Drop` wipes the bytes before
/// releasing the lock and the allocation.
pub struct SecretVec {
    bytes: Vec<u8>,
    locked: bool,
}

impl SecretVec {
    /// Allocate a zero-filled, page-locked buffer.
    pub fn zeroed(len: usize) -> Result<Self> {
        let bytes = vec![0_u8; len];
        let mut secret = Self {
            bytes,
            locked: false,
        };
        if !secret.bytes.is_empty() {
            // SAFETY: the pointer and length describe the live Vec allocation.
            let result = unsafe {
                libc::mlock(
                    secret.bytes.as_ptr().cast::<libc::c_void>(),
                    secret.bytes.len(),
                )
            };
            if result != 0 {
                // Wipe before returning the buffer to the allocator.
                secret.bytes.zeroize();
                return Err(Error::MemoryLock(io::Error::last_os_error()));
            }
            secret.locked = true;
        }
        Ok(secret)
    }

    /// Copy data into a page-locked buffer.  The destination is locked before
    /// any secret bytes are copied into it.
    pub fn from_slice(data: &[u8]) -> Result<Self> {
        let mut secret = Self::zeroed(data.len())?;
        secret.as_mut_slice().copy_from_slice(data);
        Ok(secret)
    }

    pub(crate) fn as_slice(&self) -> &[u8] {
        &self.bytes
    }

    pub(crate) fn as_mut_slice(&mut self) -> &mut [u8] {
        &mut self.bytes
    }
}

impl Drop for SecretVec {
    fn drop(&mut self) {
        self.bytes.zeroize();
        if self.locked {
            // SAFETY: the same live allocation that was locked is being
            // unlocked.  Its bytes were just wiped.
            unsafe {
                libc::munlock(self.bytes.as_ptr().cast::<libc::c_void>(), self.bytes.len());
            }
        }
    }
}

impl fmt::Debug for SecretVec {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SecretVec")
            .field("len", &self.bytes.len())
            .field("contents", &"[redacted]")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::SecretVec;

    #[test]
    fn secret_buffer_roundtrip() {
        let secret = SecretVec::from_slice(b"private-key-material").expect("mlock works");
        assert_eq!(secret.as_slice(), b"private-key-material");
    }
}
