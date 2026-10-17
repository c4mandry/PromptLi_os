//! Process helpers: running external system tools and capturing output.
//!
//! The installer deliberately shells out to proven core tools (lsblk, sfdisk,
//! mkfs, unsquashfs, grub-install, chroot) rather than reimplementing
//! filesystem/partitioning logic in Rust. This is the "low-level via the OS"
//! approach: fast, correct, and auditable.

use std::io;
use std::path::Path;
use std::process::{Command, Output};

/// Resolve a tool to an absolute path. The installer runs under `sudo`,
/// whose sanitized PATH (`secure_path`) sometimes omits /usr/sbin and /sbin —
/// this makes `sfdisk`, `mkfs.*`, `grub-install` etc. fail to spawn with
/// "No such file or directory (os error 2)". We resolve the known system
/// binaries to their fixed locations first, then fall back to PATH.
pub fn resolve_cmd(cmd: &str) -> String {
    for dir in ["/usr/sbin", "/sbin", "/usr/bin", "/bin"] {
        let p = Path::new(dir).join(cmd);
        if p.is_file() {
            return p.to_string_lossy().into_owned();
        }
    }
    // Not a fixed system path (e.g. a user-provided tool) — use PATH.
    cmd.to_string()
}

/// Run a command, returning its stdout on success or a descriptive io::Error.
pub fn run(cmd: &str, args: &[&str]) -> io::Result<Output> {
    let out = Command::new(resolve_cmd(cmd)).args(args).output()?;
    if out.status.success() {
        Ok(out)
    } else {
        let stderr = String::from_utf8_lossy(&out.stderr);
        Err(io::Error::new(
            io::ErrorKind::Other,
            format!("`{} {}` failed: {}", cmd, args.join(" "), stderr.trim()),
        ))
    }
}

/// Run a command, streaming its stdout/stderr to the terminal (for long steps
/// like unsquashfs where progress output is useful).
pub fn run_streaming(cmd: &str, args: &[&str]) -> io::Result<i32> {
    use std::process::Stdio;
    let status = Command::new(resolve_cmd(cmd))
        .args(args)
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()?;
    status.code().ok_or_else(|| {
        io::Error::new(io::ErrorKind::Other, format!("`{}` terminated by signal", cmd))
    })
}

/// Run a command capturing combined stdout+stderr (best-effort; used for
/// diagnostics that must not fail the install).
pub fn run_capture_combined(cmd: &str, args: &[&str]) -> String {
    match Command::new(resolve_cmd(cmd)).args(args).output() {
        Ok(o) => {
            let mut s = String::from_utf8_lossy(&o.stdout).into_owned();
            s.push_str(&String::from_utf8_lossy(&o.stderr));
            s
        }
        Err(e) => format!("(error running `{}`: {})", cmd, e),
    }
}

/// Check whether a command exists on PATH.
#[allow(dead_code)]
pub fn has(cmd: &str) -> bool {
    Command::new("sh")
        .args(["-c", &format!("command -v {} >/dev/null 2>&1", cmd)])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}
