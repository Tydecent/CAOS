use time::{format_description::well_known::Rfc3339, Duration, OffsetDateTime};

use crate::error::{Error, Result};

/// The maximum positive system-clock error accepted before the program refuses
/// to operate.  A machine built today and booted 50 years from now should be
/// investigated rather than trusted.
const MAX_CLOCK_AHEAD_SECS: i64 = 50 * 365 * 24 * 60 * 60;

/// Compile-time Unix timestamp written by `build.rs`.
pub fn build_timestamp() -> Result<i64> {
    env!("CAOS_BUILD_UNIX_TIME")
        .parse::<i64>()
        .map_err(|_| Error::Clock("the embedded build timestamp is invalid".into()))
}

pub fn now_utc() -> Result<OffsetDateTime> {
    Ok(OffsetDateTime::now_utc())
}

/// Check that the system clock is at or after the compile-time timestamp and
/// is not absurdly far in the future.
pub fn ensure_reasonable_clock(now: OffsetDateTime) -> Result<()> {
    let build = build_timestamp()?;
    let current = now.unix_timestamp();
    if current < build {
        return Err(Error::Clock(format!(
            "system clock {} is earlier than the program build time {}",
            format_timestamp(now)?,
            build
        )));
    }
    if current > build.saturating_add(MAX_CLOCK_AHEAD_SECS) {
        return Err(Error::Clock(format!(
            "system clock {} is implausibly far ahead of the program build time {}",
            format_timestamp(now)?,
            build
        )));
    }
    Ok(())
}

pub fn format_timestamp(value: OffsetDateTime) -> Result<String> {
    value
        .format(&Rfc3339)
        .map_err(|error| Error::Time(format!("cannot format timestamp: {error}")))
}

pub fn parse_timestamp(value: &str) -> Result<OffsetDateTime> {
    OffsetDateTime::parse(value, &Rfc3339)
        .map_err(|error| Error::Time(format!("invalid RFC 3339 timestamp {value:?}: {error}")))
}

pub fn checked_days(moment: OffsetDateTime, days: i64) -> Result<OffsetDateTime> {
    moment
        .checked_add(Duration::days(days))
        .ok_or_else(|| Error::Time("timestamp overflow".into()))
}

pub fn checked_seconds(moment: OffsetDateTime, seconds: i64) -> Result<OffsetDateTime> {
    moment
        .checked_add(Duration::seconds(seconds))
        .ok_or_else(|| Error::Time("timestamp overflow".into()))
}
