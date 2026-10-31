//! Read-only integrity verification.

use std::collections::HashSet;

use rcgen::KeyPair;
use time::OffsetDateTime;
use x509_parser::certificate::X509Certificate;
use x509_parser::pem::parse_x509_pem;
use x509_parser::prelude::parse_x509_certificate;
use zeroize::Zeroizing;

use crate::audit;
use crate::clock::ensure_reasonable_clock;
use crate::config::Config;
use crate::crypto::validate_envelope;
use crate::error::{Error, Result};
use crate::store;
use crate::util::{
    normalize_serial, read_public_file, require_private_mode, serial_hex, sha256_file,
};

const MAX_ROOT_KEY_ENVELOPE_BYTES: u64 = 1024 * 1024;

#[derive(Debug)]
pub struct VerifyReport {
    pub root_subject: String,
    pub intermediate_subject: String,
    pub issued_certificates: usize,
    pub revoked_certificates: usize,
    pub audit_entries: usize,
}

fn extract<'a>(der: &'a [u8], description: &str) -> Result<X509Certificate<'a>> {
    let (_, certificate) = parse_x509_certificate(der).map_err(|error| {
        Error::Verification(format!("cannot parse {description} certificate: {error}"))
    })?;
    Ok(certificate)
}

fn decode_certificate_pem(pem_bytes: &[u8], description: &str) -> Result<Vec<u8>> {
    let (_, pem) = parse_x509_pem(pem_bytes)
        .map_err(|error| Error::Verification(format!("cannot parse {description} PEM: {error}")))?;
    Ok(pem.contents)
}

fn check_certificate_time(certificate: &X509Certificate<'_>, description: &str) -> Result<()> {
    if !certificate.validity().is_valid() {
        return Err(Error::Verification(format!(
            "{description} is outside its validity period"
        )));
    }
    Ok(())
}

fn check_private_key_matches_certificate(
    key_pem: &[u8],
    certificate: &X509Certificate<'_>,
    description: &str,
) -> Result<()> {
    let key_text = std::str::from_utf8(key_pem)
        .map_err(|_| Error::Verification(format!("{description} key is not UTF-8 PEM")))?;
    let key = Zeroizing::new(KeyPair::from_pem(key_text).map_err(|error| {
        Error::Verification(format!("cannot parse {description} private key: {error}"))
    })?);
    if certificate.public_key().subject_public_key.data.as_ref() != key.public_key_raw() {
        return Err(Error::Verification(format!(
            "{description} key and certificate do not match"
        )));
    }
    Ok(())
}

/// Verify all static CA material, every issued certificate, the revocation
/// list and the audit chain.
pub fn verify(config: &Config, now: OffsetDateTime) -> Result<VerifyReport> {
    ensure_reasonable_clock(now)?;
    store::require_initialized(config)?;

    // 1. File hashes recorded after CA initialization / last mutation.
    let _manifest = store::check_integrity(config)?;

    // 2. Permission checks for private material.
    require_private_mode(&config.root_key_path())?;
    require_private_mode(&config.intermediate_key_path())?;
    require_private_mode(&config.audit_file())?;

    // 3. Structural validation of the encrypted root key envelope.
    let root_envelope = read_public_file(&config.root_key_path(), MAX_ROOT_KEY_ENVELOPE_BYTES)?;
    validate_envelope(&root_envelope)?;

    let metadata = store::load_metadata(config)?;
    let revocations = store::load_revocations(config)?;

    // 4. Parse and cryptographically validate the CA chain.
    let root_pem = store::read_public_cert(config, &config.root_cert_path())?;
    let intermediate_pem = store::read_public_cert(config, &config.intermediate_cert_path())?;
    let root_der = decode_certificate_pem(&root_pem, "root CA")?;
    let intermediate_der = decode_certificate_pem(&intermediate_pem, "intermediate CA")?;
    let root = extract(&root_der, "root CA")?;
    let intermediate = extract(&intermediate_der, "intermediate CA")?;

    check_certificate_time(&root, "root CA")?;
    check_certificate_time(&intermediate, "intermediate CA")?;
    if !root.is_ca() {
        return Err(Error::Verification(
            "root certificate is not marked as a CA".into(),
        ));
    }
    if !intermediate.is_ca() {
        return Err(Error::Verification(
            "intermediate certificate is not marked as a CA".into(),
        ));
    }
    root.verify_signature(None)
        .map_err(|error| Error::Verification(format!("root CA self-signature: {error}")))?;
    intermediate
        .verify_signature(Some(root.public_key()))
        .map_err(|error| {
            Error::Verification(format!(
                "intermediate CA signature does not verify against the root CA: {error}"
            ))
        })?;

    let root_serial = serial_hex(root.raw_serial());
    let intermediate_serial = serial_hex(intermediate.raw_serial());
    if normalize_serial(&metadata.root.serial)? != root_serial {
        return Err(Error::Verification(
            "root certificate serial does not match the CA metadata".into(),
        ));
    }
    if normalize_serial(&metadata.intermediate.serial)? != intermediate_serial {
        return Err(Error::Verification(
            "intermediate certificate serial does not match the CA metadata".into(),
        ));
    }

    let intermediate_key_pem = store::read_secret_file(&config.intermediate_key_path())?;
    check_private_key_matches_certificate(
        intermediate_key_pem.as_slice(),
        &intermediate,
        "intermediate CA",
    )?;

    // 5. Every issued certificate must have a matching hash, serial and
    //    signature, and the revocation list may only reference issued serials.
    let mut issued_serials = HashSet::new();
    for issued in &metadata.issued {
        let serial = normalize_serial(&issued.serial)?;
        if !issued_serials.insert(serial.clone()) {
            return Err(Error::Verification(format!(
                "duplicate issued serial {serial} in metadata"
            )));
        }
        let cert_path = store::issued_cert_path(config, &serial);
        let (hash, _) = sha256_file(&cert_path)?;
        if hash != issued.certificate_sha256 {
            return Err(Error::Verification(format!(
                "issued certificate {} does not match its recorded hash",
                cert_path.display()
            )));
        }
        let cert_pem = store::read_public_cert(config, &cert_path)?;
        let der = decode_certificate_pem(&cert_pem, "issued certificate")?;
        let certificate = extract(&der, "issued certificate")?;
        if serial_hex(certificate.raw_serial()) != serial {
            return Err(Error::Verification(format!(
                "issued certificate {} has a different serial number",
                cert_path.display()
            )));
        }
        certificate
            .verify_signature(Some(intermediate.public_key()))
            .map_err(|error| {
                Error::Verification(format!(
                    "issued certificate {serial} is not signed by the intermediate CA: {error}"
                ))
            })?;
        if certificate.is_ca() {
            return Err(Error::Verification(format!(
                "issued end-entity certificate {serial} is marked as a CA"
            )));
        }
        check_certificate_time(&certificate, &format!("issued certificate {serial}"))?;
        let key_path = store::issued_key_path(config, &serial);
        require_private_mode(&key_path)?;
        let leaf_key = store::read_secret_file(&key_path)?;
        check_private_key_matches_certificate(
            leaf_key.as_slice(),
            &certificate,
            &format!("issued certificate {serial}"),
        )?;
    }

    let mut revoked_serials = HashSet::new();
    for revoked in &revocations.revoked {
        let serial = normalize_serial(&revoked.serial)?;
        if !revoked_serials.insert(serial.clone()) {
            return Err(Error::Verification(format!(
                "duplicate revoked serial {serial}"
            )));
        }
        if !issued_serials.contains(&serial) {
            return Err(Error::Verification(format!(
                "revocation list references unknown serial {serial}"
            )));
        }
    }

    // 6. Audit hash chain, time source and monotonic timestamps.
    let audit_summary = audit::verify_chain(&config.audit_file(), now)?;

    Ok(VerifyReport {
        root_subject: root.tbs_certificate.subject.to_string(),
        intermediate_subject: intermediate.tbs_certificate.subject.to_string(),
        issued_certificates: metadata.issued.len(),
        revoked_certificates: revocations.revoked.len(),
        audit_entries: audit_summary.entries,
    })
}
