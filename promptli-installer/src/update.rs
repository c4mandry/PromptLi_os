//! The `promptli-update` command.
//!
//! promptLi OS has two update layers:
//!   1. Debian/apt packages (and AUR via the pacman wrapper) — the base OS.
//!   2. The promptLi release layer (config, scripts, installer, the
//!      OS version string) — shipped inside the ISO and updated from the
//!      website's `/api/os/latest` manifest.
//!
//!   promptli-update --check   → apt update + report upgradable, AND report
//!                               whether a newer promptLi release exists.
//!   promptli-update --apply   → apt upgrade, AND (if a newer promptLi
//!                               release exists) download + apply it.
//!
//! Since 1.32.0 the release layer is downloaded as a SMALL tar.zst payload
//! (`/api/os/update`) containing only the promptLi-owned paths — not the
//! full ~1.2 GB ISO. Releases that predate the payload fall back to the
//! ISO path automatically.

use crate::common::InstallState;
use crate::proc;
use std::io;

fn run_apt(args: &[&str]) -> io::Result<i32> {
    let code = proc::run_streaming("apt-get", args)?;
    Ok(code)
}

/// Read the configured site URL (from install.json via *state*, else the
/// default) so machines enrolled against a custom --site keep updating from
/// that host.
fn site_url(state: Option<&InstallState>) -> String {
    match state {
        Some(s) if !s.site_url.trim().is_empty() => s.site_url.clone(),
        _ => crate::common::DEFAULT_SITE_URL.to_string(),
    }
}

/// Look up the latest promptLi OS version from the website. Returns None when
/// the endpoint is unreachable (offline → never blocks a plain apt update).
fn latest_promptli_version(state: Option<&InstallState>) -> Option<String> {
    let manifest = crate::http_client::fetch_latest(&site_url(state))?;
    manifest["version"].as_str().map(|s| s.to_string())
}

/// Check whether a newer promptLi release exists than the installed version.
fn newer_release_available(state: Option<&InstallState>) -> Option<(String, String)> {
    let latest = latest_promptli_version(state)?;
    let current = crate::common::distro_version();
    if crate::common::compare_version(&latest, &current) == std::cmp::Ordering::Greater {
        Some((latest, current))
    } else {
        None
    }
}

pub fn run_check(state: Option<InstallState>) -> io::Result<i32> {
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
    match newer_release_available(state.as_ref()) {
        Some((latest, current)) => {
            println!();
            println!("A newer promptLi OS release is available: {latest} (installed {current}).");
            println!("Run `sudo promptli-update --apply` to upgrade.");
        }
        None => {}
    }
    Ok(0)
}

pub fn run_apply(state: Option<InstallState>, _dest: &str) -> io::Result<i32> {
    // 1. apt upgrade first (the base Debian packages).
    println!("Updating promptLi OS (apt-get upgrade) ...");
    let code = run_apt(&["upgrade", "-y"])?;

    // 2. Then the promptLi release layer, if a newer release exists.
    // The manifest is fetched once and reused for both the version check
    // and the payload download, so a manifest swap mid-update can't race.
    let site = site_url(state.as_ref());
    let manifest = crate::http_client::fetch_latest(&site);

    let newer = match manifest.as_ref().and_then(|m| m["version"].as_str()) {
        Some(latest) => {
            let current = crate::common::distro_version();
            if crate::common::compare_version(latest, &current) == std::cmp::Ordering::Greater {
                Some((latest.to_string(), current))
            } else {
                None
            }
        }
        None => None,
    };

    match newer {
        Some((latest, current)) => {
            println!();
            println!("Upgrading promptLi OS {current} -> {latest} ...");
            let r = apply_release(&latest, &site, manifest.as_ref());
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

/// Apply the new release layer: prefer the small update payload; fall back
/// to the full ISO for releases built before the payload existed.
fn apply_release(
    version: &str,
    site: &str,
    manifest: Option<&serde_json::Value>,
) -> io::Result<()> {
    let has_payload = manifest
        .and_then(|m| m["update_filename"].as_str())
        .map(|f| !f.is_empty())
        .unwrap_or(false);

    if has_payload {
        apply_update_payload(version, site, manifest.unwrap())
    } else {
        apply_from_iso(version, site)
    }
}

/// Fast path: download the small tar.zst payload and extract it over `/`.
/// This is what makes a release update take seconds instead of ~18 minutes.
fn apply_update_payload(
    version: &str,
    site: &str,
    manifest: &serde_json::Value,
) -> io::Result<()> {
    let tarball = "/var/tmp/promptli-update.tar.zst";
    let expected_sha = manifest["update_sha256"].as_str().unwrap_or("").to_string();

    println!("Downloading promptLi OS {version} update payload ...");
    let url = format!("{}/api/os/update", site);
    let dl = proc::run_capture_combined(
        "sh",
        &[
            "-c",
            &format!("curl -fL --retry 2 -o {tarball} '{url}' 2>&1 || wget -O {tarball} '{url}' 2>&1"),
        ],
    );
    if !dl.is_empty() {
        eprintln!("{dl}");
    }
    if !std::path::Path::new(tarball).is_file() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "update payload download failed",
        ));
    }

    // Verify the sha256 when the manifest carries one (corruption guard).
    if !expected_sha.is_empty() {
        let got = proc::run_capture_combined(
            "sh",
            &["-c", &format!("sha256sum {tarball} | cut -d' ' -f1 | tr -d '\\n'")],
        );
        if got.trim() != expected_sha {
            let _ = std::fs::remove_file(tarball);
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "update payload sha256 mismatch — download corrupted?",
            ));
        }
        println!("  [✓] sha256 verified");
    }

    // Remember the fast/norm mode BEFORE /etc/os-release gets overwritten.
    let mode = proc::run_capture_combined(
        "sh",
        &[
            "-c",
            "sed -n 's/^PRETTY_NAME=\".* \\(fast\\|norm\\)\"$/\\1/p' /etc/os-release | tail -1 | tr -d '\\n'",
        ],
    );

    println!("Applying update payload ...");
    let out = proc::run_capture_combined(
        "sh",
        &["-c", &format!("tar --zstd -xf {tarball} -C / 2>&1")],
    );
    if !out.is_empty() {
        eprintln!("{out}");
    }

    // Re-insert the fast/norm suffix INSIDE the quotes (the suffix must
    // never be appended after the closing quote — a shipped bug once).
    let suffix = mode.trim();
    if !suffix.is_empty() {
        let suf = format!(" {suffix}");
        let _ = proc::run_capture_combined(
            "sh",
            &[
                "-c",
                &format!(
                    "sed -i -E 's|^(PRETTY_NAME=\"[^\"]*)|\\1{suf}|; s|^(VERSION=\"[^\"]*)|\\1{suf}|' /etc/os-release"
                ),
            ],
        );
    }

    finish_release_layer();
    let _ = std::fs::remove_file(tarball);
    Ok(())
}

/// Post-extraction steps shared by the payload and ISO paths: binary
/// permissions, the libalpm symlink + pacman db dirs AUR helpers need, and
/// the initramfs/grub rebuild when the payload carried a newer kernel.
fn finish_release_layer() {
    proc::run_capture_combined(
        "sh",
        &["-c", "chmod +x /usr/local/bin/pacman /usr/local/bin/promptli* /usr/local/bin/locakhost 2>/dev/null || true; \
                   ALPM=$(find /usr/lib -name 'libalpm.so.*' 2>/dev/null | head -1); \
                   if [ -n \"$ALPM\" ] && [ ! -e \"${ALPM%.so.*}.so\" ] && [ ! -e /usr/lib/x86_64-linux-gnu/libalpm.so ]; then \
                       ln -sf \"$ALPM\" /usr/lib/x86_64-linux-gnu/libalpm.so; \
                   fi; \
                   mkdir -p /var/lib/pacman/local /var/lib/pacman/sync"],
    );

    // Kernel updates: when the release layer ships a NEWER kernel than the
    // running one, build its initramfs (the live initrd is live-boot only)
    // and refresh the bootloader so `pacman -Syu` upgrades the kernel too.
    // When the kernel did NOT change, still rebuild the running initramfs so
    // updated /etc/initramfs-tools config (e.g. the forced USB keyboard
    // modules) takes effect immediately.
    proc::run_capture_combined(
        "sh",
        &[
            "-c",
            "NEWKREL=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1); \
             if [ -n \"$NEWKREL\" ] && [ \"$NEWKREL\" != \"$(uname -r)\" ]; then \
                 echo \"New kernel $NEWKREL found - building initramfs...\"; \
                 update-initramfs -c -k \"$NEWKREL\" 2>&1 || true; \
                 update-grub 2>&1 || true; \
             else \
                 echo \"Rebuilding initramfs for $(uname -r)...\"; \
                 update-initramfs -u -k \"$(uname -r)\" 2>&1 || true; \
             fi",
        ],
    );

    // Boot branding: force GRUB_DISTRIBUTOR to promptLi OS (installs made
    // from older media can carry a baked-in Debian value), drop the
    // " GNU/Linux" suffix 10_linux appends to menu entries, and regenerate
    // grub.cfg so the next boot shows promptLi — never Debian.
    proc::run_capture_combined(
        "sh",
        &[
            "-c",
            r#"GRUBF=/etc/default/grub
               if grep -q '^GRUB_DISTRIBUTOR=' "$GRUBF" 2>/dev/null; then
                   sed -i -E 's|^GRUB_DISTRIBUTOR=.*|GRUB_DISTRIBUTOR="promptLi OS"|' "$GRUBF"
               else
                   echo 'GRUB_DISTRIBUTOR="promptLi OS"' >> "$GRUBF"
               fi
               if [ -f /etc/grub.d/10_linux ]; then
                   sed -i 's|OS="${GRUB_DISTRIBUTOR} GNU/Linux"|OS="${GRUB_DISTRIBUTOR}"|' /etc/grub.d/10_linux
               fi
               update-grub 2>&1 || true"#,
        ],
    );
}

/// Legacy path: download the full ISO and unsquashfs the promptLi-owned
/// paths. Used only when the manifest has no update payload (releases
/// before 1.32.0).
fn apply_from_iso(version: &str, site: &str) -> io::Result<()> {
    let iso = "/var/tmp/promptli-update.iso";
    let mnt = "/var/tmp/promptli-update-mnt";

    println!("Downloading promptLi OS {version} ISO (no update payload for this release) ...");
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
    let paths = "opt/promptli etc/fastfetch etc/skel etc/zsh \
                 etc/promptli/autostart.d \
                 etc/profile.d/promptli-version.sh etc/profile.d/promptli-path.sh \
                 usr/local/bin/pacman \
                 usr/local/bin/promptli usr/local/bin/promptli-term usr/local/bin/promptli-kb \
                 usr/local/bin/promptli-fast usr/local/bin/promptli-norm \
                 usr/local/bin/promptli-install usr/local/bin/promptli-update \
                 usr/local/bin/promptli-getty usr/local/bin/locakhost \
                 usr/local/bin/mist usr/share/makedeb/makedeb-rs \
                 boot lib/modules \
                 usr/local/bin/starship usr/share/oh-my-zsh";
    let out = proc::run_capture_combined(
        "sh",
        &["-c", &format!("unsquashfs -f -no-progress -d / {sq} {paths} 2>&1")],
    );
    if !out.is_empty() {
        eprintln!("{out}");
    }

    // Update the version in /etc/os-release while preserving the fast/norm
    // mode suffix (promptli-fast/norm append it INSIDE the quotes of
    // PRETTY_NAME and VERSION).
    let _ = proc::run_capture_combined(
        "sh",
        &[
            "-c",
            &format!(
                "unsquashfs -f -no-progress -d /tmp/promptli-osrel {sq} etc/os-release 2>/dev/null && \
                 MODE=$(sed -n 's/^PRETTY_NAME=\".* \\(fast\\|norm\\)\"$/\\1/p' /etc/os-release | tail -1); \
                 cp -f /tmp/promptli-osrel/etc/os-release /etc/os-release; \
                 if [ -n \"$MODE\" ]; then \
                   sed -i -E 's|^(PRETTY_NAME=\"[^\"]*)|\\1 '\"$MODE\"'|; s|^(VERSION=\"[^\"]*)|\\1 '\"$MODE\"'|' /etc/os-release; \
                 fi; \
                 rm -rf /tmp/promptli-osrel"
            ),
        ],
    );

    finish_release_layer();

    proc::run_capture_combined("sh", &["-c", "umount /var/tmp/promptli-update-mnt 2>/dev/null || true"]);
    let _ = std::fs::remove_file(iso);
    let _ = std::fs::remove_dir(mnt);
    Ok(())
}
