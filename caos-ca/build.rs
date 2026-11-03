//! Embed the build timestamp and, when the source tree has Git metadata, the
//! tag and commit that produced the binary.  `caos-ca --version` reports this
//! identity so an operator can tell exactly which revision a CA device runs.
//!
//! Every Git lookup is best-effort: builds from an exported tarball, a missing
//! `git` binary or a repository without tags simply produce a shorter version
//! string instead of failing the build.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

/// Number of hexadecimal characters kept from the commit hash.
const SHORT_COMMIT_LEN: usize = 7;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    let seconds = match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_secs(),
        Err(error) => panic!("build machine clock is before the Unix epoch: {error}"),
    };

    println!("cargo:rustc-env=CAOS_BUILD_UNIX_TIME={seconds}");

    // Rebuild the identity when the checked-out revision changes, not only when
    // a source file does.
    watch_git_metadata();

    if let Some(tag) = git_tag() {
        println!("cargo:rustc-env=CAOS_BUILD_GIT_TAG={tag}");
    }
    if let Some(commit) = git_commit() {
        println!("cargo:rustc-env=CAOS_BUILD_GIT_COMMIT={commit}");
    }
}

/// The tag pointing exactly at `HEAD`, if any.  Branches that are merely *near*
/// a tag intentionally report no tag rather than a `describe` distance suffix.
fn git_tag() -> Option<String> {
    git_output(&["describe", "--tags", "--exact-match", "HEAD"])
}

/// The first seven hexadecimal characters of the checked-out commit.
fn git_commit() -> Option<String> {
    let hash = git_output(&["rev-parse", "--verify", "HEAD"])?;
    if hash.len() < SHORT_COMMIT_LEN || !hash.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    Some(hash.chars().take(SHORT_COMMIT_LEN).collect())
}

/// Ask Cargo to re-run this script when `HEAD` or the ref it points at changes.
fn watch_git_metadata() {
    let Some(head) = git_path("HEAD") else {
        return;
    };
    println!("cargo:rerun-if-changed={}", head.display());

    // A release tag may be created after the last build, so an incremental
    // rebuild must still notice it.  Watching the tag directory also covers
    // tags pointing at an already checked-out detached HEAD.
    for name in ["refs/tags", "packed-refs"] {
        if let Some(path) = git_path(name) {
            println!("cargo:rerun-if-changed={}", path.display());
        }
    }

    let Ok(contents) = std::fs::read_to_string(&head) else {
        return;
    };
    let Some(reference) = contents.trim().strip_prefix("ref: ") else {
        return;
    };
    if let Some(path) = git_path(reference) {
        println!("cargo:rerun-if-changed={}", path.display());
    }
}

/// Resolve a path inside the Git directory, anchored to this package.
fn git_path(name: &str) -> Option<PathBuf> {
    let reported = git_output(&["rev-parse", "--git-path", name])?;
    let path = Path::new(&reported);
    Some(if path.is_absolute() {
        path.to_path_buf()
    } else {
        Path::new(env!("CARGO_MANIFEST_DIR")).join(path)
    })
}

/// Run Git in the package directory and return the first line of stdout.
fn git_output(args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .env("GIT_OPTIONAL_LOCKS", "0")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8(output.stdout).ok()?;
    let line = stdout.lines().next()?.trim();
    // Reject anything that would corrupt the `cargo:` directive stream.
    if line.is_empty() || line.chars().any(char::is_control) {
        return None;
    }
    Some(line.to_string())
}
