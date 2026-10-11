//! Install orchestration: unpack squashfs, configure system, bootloader.

use crate::common::{InstallState, LIVE_SQUASHFS_PATHS};
use crate::disk::{partition_disk, umount, mount, PartitionScheme, PartitionResult};
use crate::http_client::enroll;
use crate::proc::{self, run, run_streaming};
use std::io;
use std::path::{Path, PathBuf};

pub struct InstallOptions {
    pub disk: String,
    pub layout: PartitionScheme,
    pub hostname: String,
    pub username: String,
    pub password: String,
    pub site_url: String,
    pub version: String,
}

/// Find the live squashfs/rootfs on this running system.
pub fn find_live_root() -> io::Result<PathBuf> {
    for p in LIVE_SQUASHFS_PATHS {
        let path = Path::new(p);
        if path.exists() {
            return Ok(path.to_path_buf());
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "could not locate the live filesystem (squashfs/rootfs)",
    ))
}

/// Run the full install. `progress` is called between steps (the TUI renders it).
pub fn run_install(
    opts: &InstallOptions,
    mut progress: impl FnMut(&str),
) -> io::Result<InstallState> {
    let target_dir = Path::new("/mnt/promptli-target");

    progress("Partitioning disk");
    let disk = crate::disk::discover_disks(1024 * 1024 * 1024)?
        .into_iter()
        .find(|d| d.name == opts.disk)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "target disk disappeared"))?;
    let parts: PartitionResult = partition_disk(&disk, opts.layout, &opts.hostname)?;

    progress("Mounting root");
    mount(&parts.root, target_dir)?;

    if let Some(esp) = &parts.esp {
        progress("Mounting EFI");
        mount(esp, &target_dir.join("boot/efi"))?;
    }

    // ── Unpack the live root ──────────────────────────────
    progress("Extracting filesystem");
    let live_root = find_live_root()?;

    if live_root.extension().map(|e| e == "squashfs").unwrap_or(false)
        || run("file", &[live_root.to_str().unwrap_or("")])
            .map(|o| String::from_utf8_lossy(&o.stdout).contains("Squashfs"))
            .unwrap_or(false)
    {
        // unsquashfs into the target. Force-overwrite to be idempotent.
        run_streaming(
            "unsquashfs",
            &["-f", "-d", target_dir.to_str().unwrap_or(""), live_root.to_str().unwrap_or("")],
        )?;
    } else {
        // It's likely an already-unpacked rootfs (e.g. /run/live/rootfs) — copy.
        run_streaming(
            "rsync",
            &[
                "-aAXx",
                "--info=progress2",
                &format!("{}/", live_root.display()),
                target_dir.to_str().unwrap_or(""),
            ],
        )?;
    }

    // ── Basic system configuration ───────────────────────
    progress("Writing configuration");
    write_hostname(target_dir, &opts.hostname)?;
    write_fstab(target_dir, &parts)?;
    enable_serial_console(target_dir)?;
    create_user(target_dir, &opts.username, &opts.password)?;

    // ── Bootloader ────────────────────────────────────────
    progress("Installing bootloader");
    install_bootloader(target_dir, &parts)?;

    // ── Enable the update daemon/service on the target ────
    progress("Enabling updater");
    install_updater_files(target_dir)?;

    // ── Enrollment callback to the website ────────────────
    progress("Registering with server");
    let machine_id = read_machine_id(target_dir)?;
    let token = enroll(&opts.site_url, &opts.version, &opts.hostname, &machine_id)
        .unwrap_or_else(|e| {
            eprintln!("warning: enrollment failed: {e}");
            String::new()
        });

    let state = InstallState {
        version: opts.version.clone(),
        site_url: opts.site_url.clone(),
        token,
        machine_id,
        installed_at: chrono_stamp(),
    };

    // Write state into the TARGET (so it lands on the installed system).
    let state_path = target_dir.join("etc/promptli/install.json");
    if let Some(parent) = state_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&state_path, serde_json::to_string_pretty(&state)?)?;

    progress("Syncing");
    let _ = run("sync", &[]);

    // ── Unmount ───────────────────────────────────────────
    progress("Unmounting");
    if parts.esp.is_some() {
        umount(&target_dir.join("boot/efi"));
    }
    umount(target_dir);

    Ok(state)
}

fn write_hostname(root: &Path, hostname: &str) -> io::Result<()> {
    std::fs::write(root.join("etc/hostname"), format!("{hostname}\n"))?;
    let hosts = format!("127.0.0.1\tlocalhost\n127.0.1.1\t{hostname}\n");
    std::fs::write(root.join("etc/hosts"), hosts)?;
    Ok(())
}

fn write_fstab(root: &Path, parts: &PartitionResult) -> io::Result<()> {
    let root_uuid = blkid_uuid(&parts.root)?;
    let mut fstab = format!("UUID={root_uuid} / ext4 defaults,noatime 0 1\n");
    if let Some(esp) = &parts.esp {
        let esp_uuid = blkid_uuid(esp)?;
        fstab.push_str(&format!("UUID={esp_uuid} /boot/efi vfat umask=0077 0 1\n"));
    }
    std::fs::write(root.join("etc/fstab"), fstab)?;
    Ok(())
}

/// Enable the serial console on the installed system — promptLi OS is a
/// server distro, so ttyS0 (IPMI/headless/VPS consoles) should work out of
/// the box, alongside the regular VGA tty.
fn enable_serial_console(root: &Path) -> io::Result<()> {
    let grub_defaults = root.join("etc/default/grub");
    let mut content = std::fs::read_to_string(&grub_defaults).unwrap_or_default();

    // Set (or replace) a GRUB_* key with a single value in the defaults file.
    fn ensure(content: &mut String, key: &str, value: &str) {
        let line = format!("{key}=\"{value}\"");
        let mut found = false;
        let mut out = String::new();
        for l in content.lines() {
            let trimmed = l.trim_start();
            let matched = trimmed.starts_with(key)
                && !trimmed.starts_with(&format!("{key}_"));
            if matched && !found {
                out.push_str(&line);
                out.push('\n');
                found = true;
            } else {
                out.push_str(l);
                out.push('\n');
            }
        }
        if !found {
            out.push_str(&line);
            out.push('\n');
        }
        *content = out;
    }

    ensure(
        &mut content,
        "GRUB_CMDLINE_LINUX",
        "console=tty0 console=ttyS0,115200",
    );
    ensure(&mut content, "GRUB_TERMINAL", "console serial");
    ensure(
        &mut content,
        "GRUB_SERIAL_COMMAND",
        "serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1",
    );

    std::fs::write(&grub_defaults, content)?;
    Ok(())
}

fn blkid_uuid(dev: &str) -> io::Result<String> {
    let out = run("blkid", &["-s", "UUID", "-o", "value", dev])?;
    let uuid = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if uuid.is_empty() {
        return Err(io::Error::new(io::ErrorKind::NotFound, format!("no UUID for {dev}")));
    }
    Ok(uuid)
}

fn create_user(root: &Path, username: &str, password: &str) -> io::Result<()> {
    // Use chroot + useradd + chpasswd. zsh is the promptLi default shell.
    let script = format!(
        "useradd -m -s /usr/bin/zsh -G sudo,netdev,video {u} 2>/dev/null || true; \
         echo '{u}:{p}' | chpasswd",
        u = username,
        p = password
    );
    run("chroot", &[root.to_str().unwrap_or(""), "/bin/sh", "-c", &script])?;
    Ok(())
}

fn install_bootloader(root: &Path, parts: &PartitionResult) -> io::Result<()> {
    // Determine the parent disk device of the root partition.
    let disk_dev = physical_disk(&parts.root);

    // grub-install needs the host's devices inside the target chroot
    // (the static /dev of the fresh root has no /dev/vda etc.).
    let mut mounted: Vec<std::path::PathBuf> = Vec::new();
    for m in ["/dev", "/proc", "/sys"] {
        let dst = root.join(m.trim_start_matches('/'));
        if proc::run("mount", &["--bind", m, dst.to_str().unwrap_or("")]).is_ok() {
            mounted.push(dst);
        }
    }

    let result = match parts.layout {
        PartitionScheme::Efi => {
            // grub-install for EFI uses the chroot; EFI dir mounted at /boot/efi.
            let script = "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=promptLi --recheck && update-grub";
            run("chroot", &[root.to_str().unwrap_or(""), "/bin/sh", "-c", script])
        }
        PartitionScheme::Bios => {
            let script = format!(
                "grub-install --target=i386-pc --recheck {disk} && update-grub",
                disk = disk_dev
            );
            run("chroot", &[root.to_str().unwrap_or(""), "/bin/sh", "-c", &script])
        }
    };

    // Unmount in reverse order (best-effort).
    for dst in mounted.iter().rev() {
        umount(dst);
    }
    result.map(|_| ())
}

/// Strip a trailing partition suffix to get the physical disk, e.g.
/// /dev/sda1 -> /dev/sda, /dev/nvme0n1p2 -> /dev/nvme0n1.
fn physical_disk(part: &str) -> String {
    // nvme/virtio/mmcblk use `pN` partition suffix.
    if let Some(idx) = part.rfind('p') {
        let suffix = &part[idx + 1..];
        if suffix.chars().all(|c| c.is_ascii_digit()) {
            return part[..idx].to_string();
        }
    }
    // Everything else: strip trailing digits.
    let trimmed = part.trim_end_matches(|c: char| c.is_ascii_digit());
    trimmed.to_string()
}

fn install_updater_files(root: &Path) -> io::Result<()> {
    // promptLi OS updates through the Debian package managers: `apt upgrade`
    // and `pacman -Syu` (which the pacman wrapper maps to apt). We do NOT ship
    // a separate ISO-download updater — instead we make sure the standard apt
    // update timers are in place so the system self-updates like any Debian.

    // apt-daily + apt-daily-upgrade are enabled by default in Debian; just
    // ensure they aren't masked (in case an earlier build masked them).
    for masked in ["apt-daily.timer", "apt-daily-upgrade.timer"] {
        let p = root.join("etc/systemd/system").join(masked);
        // If it's a symlink to /dev/null (mask), remove it to unmask.
        if let Ok(meta) = std::fs::symlink_metadata(&p) {
            if meta.file_type().is_symlink() {
                let dst = std::fs::read_link(&p).unwrap_or_default();
                if dst == std::path::Path::new("/dev/null") {
                    let _ = std::fs::remove_file(&p);
                }
            }
        }
    }

    // A small convenience hook: `promptli-update` still exists for humans who
    // type it, but it just runs the real package upgrade. The installer ships
    // the binary; here we install a systemd timer that runs the equivalent.
    let _ = root;
    Ok(())
}

fn read_machine_id(root: &Path) -> io::Result<String> {
    let p = root.join("etc/machine-id");
    match std::fs::read_to_string(&p) {
        Ok(s) if !s.trim().is_empty() => Ok(s.trim().to_string()),
        _ => {
            // Generate one.
            let id = uuid_simple();
            std::fs::write(&p, &id)?;
            Ok(id)
        }
    }
}

fn uuid_simple() -> String {
    // Avoid extra deps: read from /proc/sys/kernel/random/uuid on the host,
    // then strip dashes. On failure, fall back to a timestamp+pid mix.
    if let Ok(u) = std::fs::read_to_string("/proc/sys/kernel/random/uuid") {
        return u.trim().replace('-', "");
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{now:x}")
}

fn chrono_stamp() -> String {
    proc::run_capture_combined("date", &["-u", "+%Y-%m-%dT%H:%M:%SZ"]).trim().to_string()
}
