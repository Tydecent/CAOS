use std::path::PathBuf;

use clap::{Parser, Subcommand};

use crate::config::DEFAULT_CONFIG_PATH;

#[derive(Debug, Parser)]
#[command(
    name = "caos-ca",
    version = crate::commands::version(),
    about = "CAOS air-gapped certificate authority management tool"
)]
pub struct Cli {
    /// Read-only CAOS configuration file.
    #[arg(
        long,
        global = true,
        value_name = "FILE",
        default_value = DEFAULT_CONFIG_PATH
    )]
    pub config: PathBuf,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Create the root CA and intermediate CA.
    Init,

    /// Issue an end-entity certificate with the intermediate CA.
    Issue {
        /// Certificate common name.
        #[arg(long, value_name = "NAME")]
        cn: String,

        /// Subject alternative name; may be a DNS name or IP address. Repeatable.
        #[arg(long = "san", value_name = "DNS/IP")]
        sans: Vec<String>,
    },

    /// List issued certificates.
    List,

    /// Revoke a certificate by serial number.
    Revoke {
        /// Certificate serial number in hexadecimal.
        #[arg(long, value_name = "HEX")]
        serial: String,
    },

    /// Verify the audit chain, CA files and system clock.
    Verify,
}
