//! Root-CA key protection at rest.
//!
//! Passphrase handling and all cryptographic operations are delegated to
//! audited crates: Argon2id for key derivation, ChaCha20-Poly1305 for
//! authenticated encryption, and `ring` as the CSPRNG.
//!
//! Envelope format (all integers little-endian):
//!
//! ```text
//! offset  size  field
//!      0     8  magic "CAOSRK01"
//!      8     1  format version (1)
//!      9     4  Argon2 memory cost in KiB
//!     13     4  Argon2 iterations
//!     17     4  Argon2 lanes
//!     21    16  salt
//!     37    12  nonce
//!     49     N  ChaCha20-Poly1305 ciphertext || 16-byte tag
//! ```
//!
//! The header is associated data for the AEAD, so modifications to the
//! algorithm parameters are detected during decryption.

use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use ring::rand::{SecureRandom, SystemRandom};
use zeroize::Zeroizing;

use crate::error::{Error, Result};
use crate::secure::SecretVec;

pub const ENVELOPE_MAGIC: [u8; 8] = *b"CAOSRK01";
pub const ENVELOPE_VERSION: u8 = 1;
pub const ARGON2_MEMORY_KIB: u32 = 64 * 1024;
pub const ARGON2_ITERATIONS: u32 = 3;
pub const ARGON2_LANES: u32 = 1;
const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;
const HEADER_LEN: usize = 8 + 1 + 4 + 4 + 4 + SALT_LEN + NONCE_LEN;
const AAD_LABEL: &[u8] = b"CAOS root CA private key v1";

pub fn prompt_new_root_passphrase() -> Result<Zeroizing<String>> {
    let first =
        rpassword::prompt_password("Enter a new root-CA key passphrase (at least 12 characters): ")
            .map_err(|error| Error::Passphrase(format!("cannot read passphrase: {error}")))?;
    let first = Zeroizing::new(first);
    if first.len() < 12 {
        return Err(Error::Passphrase(
            "the root-CA key passphrase must be at least 12 characters long".into(),
        ));
    }

    let second =
        rpassword::prompt_password("Repeat the root-CA key passphrase: ").map_err(|error| {
            Error::Passphrase(format!("cannot read passphrase confirmation: {error}"))
        })?;
    let second = Zeroizing::new(second);
    if first.as_str() != second.as_str() {
        return Err(Error::Passphrase("the passphrases do not match".into()));
    }
    Ok(first)
}

/// Encrypt a PEM-encoded root private key.  The returned envelope is safe to
/// write to disk; the passphrase and derived key are wiped on drop.
pub fn encrypt_root_key(plaintext: &[u8], passphrase: &str) -> Result<Vec<u8>> {
    if plaintext.is_empty() {
        return Err(Error::Crypto("cannot encrypt an empty private key".into()));
    }

    let rng = SystemRandom::new();
    let mut salt = [0_u8; SALT_LEN];
    rng.fill(&mut salt)
        .map_err(|_| Error::Crypto("CSPRNG failure while generating salt".into()))?;
    let mut nonce = [0_u8; NONCE_LEN];
    rng.fill(&mut nonce)
        .map_err(|_| Error::Crypto("CSPRNG failure while generating nonce".into()))?;

    let params = Params::new(ARGON2_MEMORY_KIB, ARGON2_ITERATIONS, ARGON2_LANES, Some(32))
        .map_err(|error| Error::Crypto(format!("invalid Argon2 parameters: {error}")))?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut derived_key = SecretVec::zeroed(32)?;
    argon2
        .hash_password_into(passphrase.as_bytes(), &salt, derived_key.as_mut_slice())
        .map_err(|error| Error::Crypto(format!("Argon2id key derivation failed: {error}")))?;

    let cipher = ChaCha20Poly1305::new(Key::from_slice(derived_key.as_slice()));
    let mut header = Vec::with_capacity(HEADER_LEN);
    header.extend_from_slice(&ENVELOPE_MAGIC);
    header.push(ENVELOPE_VERSION);
    header.extend_from_slice(&ARGON2_MEMORY_KIB.to_le_bytes());
    header.extend_from_slice(&ARGON2_ITERATIONS.to_le_bytes());
    header.extend_from_slice(&ARGON2_LANES.to_le_bytes());
    header.extend_from_slice(&salt);
    header.extend_from_slice(&nonce);

    let mut aad = Vec::with_capacity(AAD_LABEL.len() + header.len());
    aad.extend_from_slice(AAD_LABEL);
    aad.extend_from_slice(&header);
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| Error::Crypto("ChaCha20-Poly1305 encryption failed".into()))?;

    let mut envelope = header;
    envelope.extend_from_slice(&ciphertext);
    Ok(envelope)
}

/// Validate the public structure of an on-disk encrypted root key envelope.
/// This intentionally does not attempt decryption, so verification can run
/// without asking for the root passphrase.
pub fn validate_envelope(envelope: &[u8]) -> Result<()> {
    if envelope.len() < HEADER_LEN + TAG_LEN {
        return Err(Error::Integrity(
            "encrypted root key is too short to be a valid envelope".into(),
        ));
    }
    if envelope[..8] != ENVELOPE_MAGIC {
        return Err(Error::Integrity(
            "encrypted root key has an invalid magic header".into(),
        ));
    }
    if envelope[8] != ENVELOPE_VERSION {
        return Err(Error::Integrity(format!(
            "unsupported root key envelope version {}",
            envelope[8]
        )));
    }
    let memory = u32::from_le_bytes(match envelope[9..13].try_into() {
        Ok(value) => value,
        Err(_) => return Err(Error::Integrity("truncated root key header".into())),
    });
    let iterations = u32::from_le_bytes(match envelope[13..17].try_into() {
        Ok(value) => value,
        Err(_) => return Err(Error::Integrity("truncated root key header".into())),
    });
    let lanes = u32::from_le_bytes(match envelope[17..21].try_into() {
        Ok(value) => value,
        Err(_) => return Err(Error::Integrity("truncated root key header".into())),
    });
    if memory != ARGON2_MEMORY_KIB || iterations != ARGON2_ITERATIONS || lanes != ARGON2_LANES {
        return Err(Error::Integrity(
            "root key envelope uses unexpected Argon2 parameters".into(),
        ));
    }
    Ok(())
}

/// Decrypt an envelope.  This is only compiled for tests, but keeping the
/// round trip tested makes the on-disk format a maintained contract.
#[cfg(test)]
fn decrypt_root_key(envelope: &[u8], passphrase: &str) -> Result<Zeroizing<Vec<u8>>> {
    validate_envelope(envelope)?;
    let memory = u32::from_le_bytes(
        envelope[9..13]
            .try_into()
            .map_err(|_| Error::Crypto("truncated header".into()))?,
    );
    let iterations = u32::from_le_bytes(
        envelope[13..17]
            .try_into()
            .map_err(|_| Error::Crypto("truncated header".into()))?,
    );
    let lanes = u32::from_le_bytes(
        envelope[17..21]
            .try_into()
            .map_err(|_| Error::Crypto("truncated header".into()))?,
    );
    let salt = &envelope[21..21 + SALT_LEN];
    let nonce = &envelope[21 + SALT_LEN..HEADER_LEN];
    let params = Params::new(memory, iterations, lanes, Some(32))
        .map_err(|error| Error::Crypto(format!("invalid Argon2 parameters: {error}")))?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut derived_key = SecretVec::zeroed(32)?;
    argon2
        .hash_password_into(passphrase.as_bytes(), salt, derived_key.as_mut_slice())
        .map_err(|error| Error::Crypto(format!("Argon2id key derivation failed: {error}")))?;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(derived_key.as_slice()));
    let mut aad = Vec::with_capacity(AAD_LABEL.len() + HEADER_LEN);
    aad.extend_from_slice(AAD_LABEL);
    aad.extend_from_slice(&envelope[..HEADER_LEN]);
    let plaintext = cipher
        .decrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: &envelope[HEADER_LEN..],
                aad: &aad,
            },
        )
        .map_err(|_| Error::Crypto("root key decryption failed".into()))?;
    Ok(Zeroizing::new(plaintext))
}

#[cfg(test)]
mod tests {
    use super::{decrypt_root_key, encrypt_root_key, validate_envelope, ENVELOPE_MAGIC};

    #[test]
    fn envelope_round_trip_and_wrong_passphrase() {
        let secret = b"-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----\n";
        let envelope =
            encrypt_root_key(secret, "correct horse battery staple").expect("encryption succeeds");
        assert_eq!(&envelope[..8], &ENVELOPE_MAGIC);
        validate_envelope(&envelope).expect("valid envelope");
        let plaintext =
            decrypt_root_key(&envelope, "correct horse battery staple").expect("decrypts");
        assert_eq!(plaintext.as_slice(), secret);
        assert!(decrypt_root_key(&envelope, "incorrect horse battery staple").is_err());
    }

    #[test]
    fn rejects_truncated_envelope() {
        assert!(validate_envelope(b"not an envelope").is_err());
    }
}
