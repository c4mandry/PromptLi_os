//! The `promptli-update` command.
//!
//! promptLi OS has two update layers:
//!   1. Debian/apt packages (and AUR via the pacman wrapper) — the base OS.
//!   2. The promptLi release layer (aido, config, scripts, installer, the
//!      OS version string) — shipped inside the ISO and updated from the
//!      website's `/api/os/latest` manifest.
//!
//!   promptli-update --check   → apt update + report upgradable, AND report
//!                               whether a newer promptLi release exists.
//!   promptli-update --apply   → apt upgrade, AND (if a newer promptLi
//!                               release exists) download + apply it.

use crate::proc;
use std::io;

fn run_apt(args: &[&str]) -> io::Result<i32> {
    let code = proc::run_streaming("apt-get", args)?;
    Ok(code)
}

/// Read the configured site URL (from install.json, else the default).
fn site_url() -> String {
    crate::common::DEFAULT_SITE_URL.to_string()
}

/// Look up the latest promptLi OS version from the website. Returns None when
/// the endpoint is unreachable (offline → never blocks a plain apt update).
fn latest_promptli_version() -> Option<String> {
    let manifest = crate::http_client::fetch_latest(&site_url())?;
    manifest["version"].as_str().map(|s| s.to_string())
}

/// Check whether a newer promptLi release exists than the installed version.
fn newer_release_available() -> Option<(String, String)> {
    let latest = latest_promptli_version()?;
    let current = crate::common::distro_version();
    if crate::common::compare_version(&latest, &current) == std::cmp::Ordering::Greater {
        Some((latest, current))
    } else {
        None
    }
}

pub fn run_check(_state: Option<crate::common::InstallState>) -> io::Result<i32> {
    println!("Checking for package updates (apt-get update) ...");
    let code = run_apt(&["update"])?;
    if code != 0 {
        return Ok(code);
    }

    // Count upgradable packages without committing anything.
    let out = proc::run_capture_combined(
        "sh",
        &[
            "-c",
            "apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' || true",
        ],
    );
    let count = out.trim();
    if let Ok(n) = count.parse::<u32>() {
        if n > 0 {
            println!("{n} package(s) can be upgraded. Run `sudo apt upgrade` or `sudo pacman -Syu`.");
        } else {
            println!("promptLi OS is up to date.");
        }
    }

    // Report a newer promptLi release, best-effort (offline → silent).
    match newer_release_available() {
        Some((latest, current)) => {
            println!();
            println!("A newer promptLi OS release is available: {latest} (installed {current}).");
            println!("Run `sudo promptli-update --apply` to upgrade.");
        }
        None => {}
    }
    Ok(0)
}

pub fn run_apply(_state: Option<crate::common::InstallState>, _dest: &str) -> io::Result<i32> {
    // 1. apt upgrade first (the base Debian packages).
    println!("Updating promptLi OS (apt-get upgrade) ...");
    let code = run_apt(&["upgrade", "-y"])?;

    // 2. Then the promptLi release layer, if a newer release exists.
    match newer_release_available() {
        Some((latest, current)) => {
            println!();
            println!("Upgrading promptLi OS {current} -> {latest} ...");
            let r = apply_release(&latest);
            if code == 0 {
                if let Err(e) = r {
                    eprintln!("warning: promptLi release upgrade failed: {e}");
                    eprintln!("       apt packages were updated; re-run `sudo promptli-update --apply` to retry the release upgrade.");
                    return Ok(0);
                }
                println!("✅ promptLi OS updated to {latest}. Reboot to finish.");
            } else if let Err(e) = r {
                eprintln!("promptLi release upgrade failed: {e}");
            }
        }
        None => {
            if code == 0 {
                println!("✅ promptLi OS updated. Reboot if the kernel was upgraded.");
            }
        }
    }
    Ok(code)
}

/// Download the new ISO and apply the promptLi layer in place.
///
/// The ISO's live filesystem (squashfs under live/) is extracted and the
/// promptLi-owned paths (aido, config, /usr/local/bin scripts, installer,
/// and the os-release version) are copied over the running system — the
/// same "restore from ISO" path promptli-norm uses. This never repartitions
/// or touches the bootloader; it only refreshes the promptLi layer.
fn apply_release(version: &str) -> io::Result<()> {
    let iso = "/var/tmp/promptli-update.iso";
    let mnt = "/var/tmp/promptli-update-mnt";

    println!("Downloading promptLi OS {version} ISO ...");
    let site = site_url();
    let iso_path = format!("{}/api/os/iso", site);
    let dl = proc::run_capture_combined(
        "sh",
        &["-c", &format!("curl -fL --retry 2 -o {iso} '{iso_path}' 2>&1 || wget -O {iso} '{iso_path}' 2>&1")],
    );
    if !dl.is_empty() {
        eprintln!("{dl}");
    }
    if !std::path::Path::new(iso).is_file() {
        return Err(io::Error::new(io::ErrorKind::NotFound, "ISO download failed"));
    }

    println!("Extracting promptLi layer from ISO ...");
    proc::run_capture_combined("sh", &["-c", &format!("mkdir -p {mnt} && mount -o loop,ro {iso} {mnt} 2>/dev/null || true")]);
    let sq = format!("{mnt}/live/filesystem.squashfs");
    if !std::path::Path::new(&sq).is_file() {
        proc::run_capture_combined("sh", &["-c", "umount /var/tmp/promptli-update-mnt 2>/dev/null || true"]);
        return Err(io::Error::new(io::ErrorKind::NotFound, "filesystem.squashfs not found in ISO"));
    }

    // Unsquash the promptLi-owned paths into / (overwrites in place).
    // /etc/os-release is handled separately below so the fast/norm mode
    // suffix survives the upgrade.
    let paths = "opt/aido opt/promptli etc/fastfetch etc/skel etc/zsh \
                 etc/profile.d/promptli-version.sh usr/local/bin/aido usr/local/bin/pacman \
                 usr/local/bin/promptli usr/local/bin/promptli-term usr/local/bin/promptli-kb \
                 usr/local/bin/promptli-fast usr/local/bin/promptli-norm \
                 usr/local/bin/promptli-install usr/local/bin/promptli-update \
                 usr/local/bin/promptli-getty usr/local/bin/locakhost \
                 usr/local/bin/starship usr/share/oh-my-zsh usr/share/aido";
    let out = proc::run_capture_combined(
        "sh",
        &["-c", &format!("unsquashfs -f -no-progress -d / {sq} {paths} 2>&1")],
    );
    if !out.is_empty() {
        eprintln!("{out}");
    }

    // Update the version in /etc/os-release while preserving the fast/norm
    // mode suffix (promptli-fast/norm append it to PRETTY_NAME and VERSION).
    let _ = proc::run_capture_combined(
        "sh",
        &[
            "-c",
            &format!(
                "unsquashfs -f -no-progress -d /tmp/promptli-osrel {sq} etc/os-release 2>/dev/null && \
                 MODE=$(sed -n 's/^PRETTY_NAME=.* (\\(fast\\|norm\\))\"/\\1/p' /etc/os-release | tail -1); \
                 cp -f /tmp/promptli-osrel/etc/os-release /etc/os-release; \
                 if [ -n \"$MODE\" ]; then \
                   sed -i -E \"s|^(PRETTY_NAME=.*)\\|\\1 $MODE\\|; s|^(VERSION=.*)\\|\\1 $MODE\\|\" /etc/os-release; \
                 fi; \
                 rm -rf /tmp/promptli-osrel"
            ),
        ],
    );

    // Fix permissions on the extracted binaries.
    proc::run_capture_combined(
        "sh",
        &["-c", "chmod +x /usr/local/bin/aido /usr/local/bin/pacman /usr/local/bin/promptli* /usr/local/bin/locakhost 2>/dev/null || true"],
    );

    proc::run_capture_combined("sh", &["-c", "umount /var/tmp/promptli-update-mnt 2>/dev/null || true"]);
    let _ = std::fs::remove_file(iso);
    let _ = std::fs::remove_dir(mnt);
    Ok(())
}
