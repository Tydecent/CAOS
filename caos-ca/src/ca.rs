//! Certificate-authority lifecycle: initialization and certificate issuance.

use std::collections::HashSet;
use std::path::PathBuf;

use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa,
    Issuer, KeyPair, KeyUsagePurpose, SerialNumber,
};
use ring::rand::{SecureRandom, SystemRandom};
use time::OffsetDateTime;
use x509_parser::pem::parse_x509_pem;
use x509_parser::prelude::parse_x509_certificate;
use zeroize::Zeroizing;

use crate::audit;
use crate::clock::{checked_days, checked_seconds, format_timestamp, parse_timestamp};
use crate::config::Config;
use crate::crypto::encrypt_root_key;
use crate::error::{Error, Result};
use crate::secure::SecretVec;
use crate::store::{self, CaMetadata, CaRecord, IssuedCertificate, RevocationList, FORMAT_VERSION};
use crate::util::{serial_hex, sha256_hex, write_new_file, PRIVATE_FILE_MODE, PUBLIC_FILE_MODE};

const ROOT_CA_DAYS: i64 = 20 * 365;
const LEAF_DAYS: i64 = 365;
const CERT_BACKDATE_SECONDS: i64 = 300;

pub struct InitOutcome {
    pub root_serial: String,
    pub intermediate_serial: String,
    pub root_cert: PathBuf,
    pub root_key: PathBuf,
    pub intermediate_cert: PathBuf,
    pub intermediate_key: PathBuf,
}

pub struct IssueOutcome {
    pub serial: String,
    pub not_after: String,
    pub certificate: PathBuf,
    pub private_key: PathBuf,
}

/// Generate a serial from the operating system CSPRNG.
fn random_serial(existing: &HashSet<String>) -> Result<([u8; 16], String)> {
    let rng = SystemRandom::new();
    for _ in 0..64 {
        let mut bytes = [0_u8; 16];
        rng.fill(&mut bytes)
            .map_err(|_| Error::Crypto("CSPRNG failure while generating serial".into()))?;
        if bytes.iter().all(|byte| *byte == 0) {
            continue;
        }
        let serial = serial_hex(&bytes);
        if !existing.contains(&serial) {
            return Ok((bytes, serial));
        }
    }
    Err(Error::Crypto(
        "could not generate a unique random serial number after 64 attempts".into(),
    ))
}

fn ca_distinguished_name(common_name: &str) -> DistinguishedName {
    let mut name = DistinguishedName::new();
    name.push(DnType::CommonName, common_name);
    name.push(DnType::OrganizationName, "CAOS");
    name.push(
        DnType::OrganizationalUnitName,
        "Air-Gapped Certificate Authority",
    );
    name
}

fn base_ca_params(
    common_name: &str,
    serial: [u8; 16],
    now: OffsetDateTime,
    constrained: bool,
) -> Result<CertificateParams> {
    let not_before = checked_seconds(now, -CERT_BACKDATE_SECONDS)?;
    let not_after = checked_days(now, ROOT_CA_DAYS)?;
    let mut params = CertificateParams::new(Vec::<String>::new())?;
    params.distinguished_name = ca_distinguished_name(common_name);
    params.serial_number = Some(SerialNumber::from_slice(&serial));
    params.is_ca = if constrained {
        IsCa::Ca(BasicConstraints::Constrained(0))
    } else {
        IsCa::Ca(BasicConstraints::Unconstrained)
    };
    params.key_usages = vec![
        KeyUsagePurpose::KeyCertSign,
        KeyUsagePurpose::CrlSign,
        KeyUsagePurpose::DigitalSignature,
    ];
    params.not_before = not_before;
    params.not_after = not_after;
    params.use_authority_key_identifier_extension = true;
    Ok(params)
}

fn validate_common_name(cn: &str) -> Result<String> {
    let trimmed = cn.trim();
    if trimmed.is_empty() {
        return Err(Error::InvalidInput(
            "certificate common name must not be empty".into(),
        ));
    }
    if trimmed.chars().any(char::is_control) {
        return Err(Error::InvalidInput(
            "certificate common name must not contain control characters".into(),
        ));
    }
    if trimmed.len() > 128 {
        return Err(Error::InvalidInput(
            "certificate common name is too long".into(),
        ));
    }
    Ok(trimmed.to_string())
}

fn key_matches_certificate(key: &KeyPair, certificate_pem: &[u8], description: &str) -> Result<()> {
    let (_, pem) = parse_x509_pem(certificate_pem)
        .map_err(|error| Error::Verification(format!("cannot parse {description} PEM: {error}")))?;
    let (_, certificate) = parse_x509_certificate(&pem.contents).map_err(|error| {
        Error::Verification(format!("cannot parse {description} certificate: {error}"))
    })?;
    let certificate_public_key = &certificate
        .tbs_certificate
        .subject_pki
        .subject_public_key
        .data;
    if certificate_public_key.as_ref() != key.public_key_raw() {
        return Err(Error::Verification(format!(
            "{description} private key does not match its certificate"
        )));
    }
    Ok(())
}

fn certificate_pem_bytes(certificate: &rcgen::Certificate) -> Vec<u8> {
    certificate.pem().into_bytes()
}

/// Initialize the CA database.  The caller must already hold the exclusive
/// runtime lock and must have checked the system clock.
pub fn initialize(config: &Config, now: OffsetDateTime, passphrase: &str) -> Result<InitOutcome> {
    store::prepare_data_directories(config)?;

    let mut known_serials = HashSet::new();
    let (root_serial, root_serial_hex) = random_serial(&known_serials)?;
    known_serials.insert(root_serial_hex.clone());
    let (intermediate_serial, intermediate_serial_hex) = random_serial(&known_serials)?;

    let root_cn = format!("{} Root CA", config.ca_name);
    let intermediate_cn = format!("{} Issuing CA", config.ca_name);
    let root_params = base_ca_params(&root_cn, root_serial, now, false)?;
    let intermediate_params = base_ca_params(&intermediate_cn, intermediate_serial, now, true)?;

    // rcgen's `zeroize` feature wipes the serialized key DER when these values
    // are dropped via Zeroizing.
    let root_key = Zeroizing::new(KeyPair::generate()?);
    let intermediate_key = Zeroizing::new(KeyPair::generate()?);

    let root_cert = root_params.self_signed(&*root_key)?;
    let root_issuer = Issuer::from_params(&root_params, &*root_key);
    let intermediate_cert = intermediate_params.signed_by(&*intermediate_key, &root_issuer)?;

    let root_cert_pem = certificate_pem_bytes(&root_cert);
    let intermediate_cert_pem = certificate_pem_bytes(&intermediate_cert);
    let intermediate_key_pem = Zeroizing::new(intermediate_key.serialize_pem());
    let intermediate_key_secret = SecretVec::from_slice(intermediate_key_pem.as_bytes())?;
    let root_key_pem = Zeroizing::new(root_key.serialize_pem());
    let root_key_secret = SecretVec::from_slice(root_key_pem.as_bytes())?;
    let encrypted_root_key = encrypt_root_key(root_key_secret.as_slice(), passphrase)?;

    let root_subject = format!("CN={root_cn},O=CAOS");
    let intermediate_subject = format!("CN={intermediate_cn},O=CAOS");
    let initialized_at = format_timestamp(now)?;
    let root_not_after = format_timestamp(root_params.not_after)?;
    let intermediate_not_after = format_timestamp(intermediate_params.not_after)?;

    write_new_file(&config.root_cert_path(), &root_cert_pem, PUBLIC_FILE_MODE)?;
    write_new_file(
        &config.intermediate_cert_path(),
        &intermediate_cert_pem,
        PUBLIC_FILE_MODE,
    )?;
    write_new_file(
        &config.intermediate_key_path(),
        intermediate_key_secret.as_slice(),
        PRIVATE_FILE_MODE,
    )?;
    write_new_file(
        &config.root_key_path(),
        &encrypted_root_key,
        PRIVATE_FILE_MODE,
    )?;

    let metadata = CaMetadata {
        format_version: FORMAT_VERSION,
        ca_name: config.ca_name.clone(),
        initialized_at: initialized_at.clone(),
        root: CaRecord {
            serial: root_serial_hex.clone(),
            subject: root_subject.clone(),
            not_before: format_timestamp(root_params.not_before)?,
            not_after: root_not_after,
        },
        intermediate: CaRecord {
            serial: intermediate_serial_hex.clone(),
            subject: intermediate_subject,
            not_before: format_timestamp(intermediate_params.not_before)?,
            not_after: intermediate_not_after,
        },
        issued: Vec::new(),
    };
    store::save_metadata(config, &metadata)?;

    let revocations = RevocationList {
        format_version: FORMAT_VERSION,
        revoked: Vec::new(),
    };
    store::save_revocations(config, &revocations)?;
    store::refresh_integrity(config, &config.ca_name, &initialized_at)?;

    audit::initialize(&config.audit_file())?;
    audit::append(
        &config.audit_file(),
        "init",
        &root_serial_hex,
        &root_subject,
        now,
    )?;

    Ok(InitOutcome {
        root_serial: root_serial_hex,
        intermediate_serial: intermediate_serial_hex,
        root_cert: config.root_cert_path(),
        root_key: config.root_key_path(),
        intermediate_cert: config.intermediate_cert_path(),
        intermediate_key: config.intermediate_key_path(),
    })
}

/// Issue one end-entity certificate using the intermediate CA.
pub fn issue(
    config: &Config,
    now: OffsetDateTime,
    common_name: &str,
    sans: &[String],
) -> Result<IssueOutcome> {
    let common_name = validate_common_name(common_name)?;
    store::require_initialized(config)?;
    store::check_integrity(config)?;

    let metadata = store::load_metadata(config)?;
    let revocations = store::load_revocations(config)?;
    let known_serials = store::all_known_serials(&metadata, &revocations);
    let (serial, serial_hex) = random_serial(&known_serials)?;

    let intermediate_cert_pem_bytes =
        store::read_public_cert(config, &config.intermediate_cert_path())?;
    let intermediate_cert_pem =
        std::str::from_utf8(&intermediate_cert_pem_bytes).map_err(|_| {
            Error::Integrity("intermediate CA certificate is not valid UTF-8 PEM".into())
        })?;
    let intermediate_key_pem = store::read_secret_file(&config.intermediate_key_path())?;
    let intermediate_key_pem = std::str::from_utf8(intermediate_key_pem.as_slice())
        .map_err(|_| Error::Integrity("intermediate CA key is not valid UTF-8 PEM".into()))?;
    let intermediate_key = Zeroizing::new(KeyPair::from_pem(intermediate_key_pem)?);
    key_matches_certificate(
        &intermediate_key,
        &intermediate_cert_pem_bytes,
        "intermediate CA",
    )?;
    let issuer = Issuer::from_ca_cert_pem(intermediate_cert_pem, &*intermediate_key)?;

    let not_before = checked_seconds(now, -CERT_BACKDATE_SECONDS)?;
    let requested_not_after = checked_days(now, LEAF_DAYS)?;
    let ca_not_after = parse_timestamp(&metadata.intermediate.not_after)?;
    let not_after = requested_not_after.min(ca_not_after);
    if not_after <= not_before {
        return Err(Error::InvalidInput(
            "the intermediate CA is no longer valid for issuing certificates".into(),
        ));
    }

    let mut params = CertificateParams::new(sans.to_vec())?;
    params.distinguished_name = ca_distinguished_name(&common_name);
    params.serial_number = Some(SerialNumber::from_slice(&serial));
    params.is_ca = IsCa::ExplicitNoCa;
    params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
    params.extended_key_usages = vec![
        ExtendedKeyUsagePurpose::ServerAuth,
        ExtendedKeyUsagePurpose::ClientAuth,
    ];
    params.not_before = not_before;
    params.not_after = not_after;
    params.use_authority_key_identifier_extension = true;

    let leaf_key = Zeroizing::new(KeyPair::generate()?);
    let certificate = params.signed_by(&*leaf_key, &issuer)?;
    let cert_pem = certificate_pem_bytes(&certificate);
    let key_pem = Zeroizing::new(leaf_key.serialize_pem());
    let key_secret = SecretVec::from_slice(key_pem.as_bytes())?;

    let certificate_path = store::issued_cert_path(config, &serial_hex);
    let private_key_path = store::issued_key_path(config, &serial_hex);
    write_new_file(&private_key_path, key_secret.as_slice(), PRIVATE_FILE_MODE)?;
    if let Err(error) = write_new_file(&certificate_path, &cert_pem, PUBLIC_FILE_MODE) {
        let _ = std::fs::remove_file(&private_key_path);
        return Err(error);
    }

    let not_after_text = format_timestamp(not_after)?;
    let issued_at = format_timestamp(now)?;
    let record = IssuedCertificate {
        serial: serial_hex.clone(),
        common_name: common_name.clone(),
        subject: format!("CN={common_name},O=CAOS"),
        san: sans.to_vec(),
        not_before: format_timestamp(not_before)?,
        not_after: not_after_text.clone(),
        issued_at,
        certificate_sha256: sha256_hex(&cert_pem),
    };

    let mut metadata = metadata;
    metadata.issued.push(record);
    if let Err(error) = store::save_metadata(config, &metadata) {
        let _ = std::fs::remove_file(&private_key_path);
        let _ = std::fs::remove_file(&certificate_path);
        return Err(error);
    }
    store::refresh_integrity(config, &config.ca_name, &format_timestamp(now)?)?;
    audit::append(
        &config.audit_file(),
        "issue",
        &serial_hex,
        &format!("CN={common_name},O=CAOS"),
        now,
    )?;

    Ok(IssueOutcome {
        serial: serial_hex,
        not_after: not_after_text,
        certificate: certificate_path,
        private_key: private_key_path,
    })
}

/// Add a serial to the revocation list.  Certificates and keys are retained in
/// the database for audit purposes.
pub fn revoke(config: &Config, now: OffsetDateTime, serial: &str, reason: &str) -> Result<()> {
    store::require_initialized(config)?;
    store::check_integrity(config)?;
    let metadata = store::load_metadata(config)?;
    let mut revocations = store::load_revocations(config)?;
    let certificate = metadata
        .issued
        .iter()
        .find(|record| record.serial == serial)
        .ok_or_else(|| Error::InvalidInput(format!("no issued certificate has serial {serial}")))?;
    if revocations
        .revoked
        .iter()
        .any(|record| record.serial == serial)
    {
        return Err(Error::InvalidInput(format!(
            "certificate {serial} is already revoked"
        )));
    }
    let subject = certificate.subject.clone();
    revocations.revoked.push(store::RevokedCertificate {
        serial: serial.to_string(),
        revoked_at: format_timestamp(now)?,
        reason: reason.to_string(),
    });
    store::save_revocations(config, &revocations)?;
    store::refresh_integrity(config, &config.ca_name, &format_timestamp(now)?)?;
    audit::append(&config.audit_file(), "revoke", serial, &subject, now)?;
    Ok(())
}

// Keep the error context helper in use in this module on platforms where no
// fsync path happens to be exercised.
#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::{random_serial, validate_common_name};

    #[test]
    fn serials_are_unique_128_bit_values() {
        let mut seen = HashSet::new();
        for _ in 0..32 {
            let (_, serial) = random_serial(&seen).expect("serial");
            assert_eq!(serial.len(), 32);
            assert!(seen.insert(serial));
        }
    }

    #[test]
    fn rejects_control_characters_in_cn() {
        assert!(validate_common_name("good.example").is_ok());
        assert!(validate_common_name("bad\nname").is_err());
        assert!(validate_common_name("   ").is_err());
    }
}
