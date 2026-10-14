//! Install orchestration: unpack squashfs, configure system, bootloader.
//!
//! Everything runs offline against the live medium; the only network use is
//! the best-effort enrollment callback to the website (non-fatal on failure).

use crate::common::{InstallState, LIVE_SQUASHFS_PATHS};
use crate::disk::{partition_disk, umount, mount, PartitionResult, PartitionScheme};
use crate::http_client::enroll;
use crate::proc::{self, run};
use std::io;
use std::path::{Path, PathBuf};

pub struct InstallOptions {
    pub disk: String,
    pub layout: PartitionScheme,
    pub swap: bool,
    pub hostname: String,
    pub username: String,
    pub password: String,
    pub root_password: String,
    pub keymap: String,
    pub timezone: String,
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
    let parts: PartitionResult = partition_disk(&disk, opts.layout, &opts.hostname, opts.swap)?;

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
        // Output is captured (not streamed) so it can't corrupt the TUI.
        run(
            "unsquashfs",
            &[
                "-f",
                "-no-progress",
                "-d",
                target_dir.to_str().unwrap_or(""),
                live_root.to_str().unwrap_or(""),
            ],
        )?;
    } else {
        // It's likely an already-unpacked rootfs (e.g. /run/live/rootfs) — copy.
        run(
            "rsync",
            &[
                "-aAXx",
                &format!("{}/", live_root.display()),
                target_dir.to_str().unwrap_or(""),
            ],
        )?;
    }

    // ── Basic system configuration ───────────────────────
    progress("Writing configuration");
    write_hostname(target_dir, &opts.hostname)?;
    write_fstab(target_dir, &parts)?;
    write_keymap(target_dir, &opts.keymap)?;
    write_timezone(target_dir, &opts.timezone)?;
    enable_serial_console(target_dir)?;
    create_user(
        target_dir,
        &opts.username,
        &opts.password,
        &opts.root_password,
    )?;

    // ── Bootloader ────────────────────────────────────────
    progress("Installing bootloader");
    install_bootloader(target_dir, &parts)?;

    // ── Enable the update daemon/service on the target ────
    progress("Enabling updater");
    install_updater_files(target_dir)?;

    // ── Enrollment callback to the website (best-effort) ──
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
    if let Some(swap) = &parts.swap {
        let swap_uuid = blkid_uuid(swap)?;
        fstab.push_str(&format!("UUID={swap_uuid} none swap sw 0 0\n"));
    }
    std::fs::write(root.join("etc/fstab"), fstab)?;
    Ok(())
}

/// Console keymap: set both the systemd vconsole keymap and Debian's
/// console-setup default so it survives reboots.
fn write_keymap(root: &Path, keymap: &str) -> io::Result<()> {
    let keymap = keymap.trim();
    if keymap.is_empty() {
        return Ok(());
    }
    // Debian's console-setup ships /etc/vconsole.conf as a symlink to
    // /etc/default/keyboard; replace it with a real file or the keyboard
    // write below would clobber the KEYMAP we just set.
    let vconsole = root.join("etc/vconsole.conf");
    if let Ok(meta) = std::fs::symlink_metadata(&vconsole) {
        if meta.file_type().is_symlink() {
            let _ = std::fs::remove_file(&vconsole);
        }
    }
    std::fs::write(
        &vconsole,
        format!("KEYMAP={keymap}\nFONT=Lat2-Terminus16\n"),
    )?;
    let keyboard = format!(
        "XKBMODEL=\"pc105\"\nXKBLAYOUT=\"{keymap}\"\nXKBVARIANT=\"\"\nXKBOPTIONS=\"\"\n"
    );
    std::fs::write(root.join("etc/default/keyboard"), keyboard)?;
    // Debian's tmpfiles rule (usr/lib/tmpfiles.d/debian.conf) re-symlinks
    // /etc/vconsole.conf to /etc/default/keyboard on every boot (L+). An
    // /etc/tmpfiles.d file with the SAME name shadows it entirely — keep
    // Debian's other rules and replace the vconsole link with a keymap file.
    std::fs::create_dir_all(root.join("etc/tmpfiles.d"))?;
    std::fs::write(
        root.join("etc/tmpfiles.d/debian.conf"),
        format!(
            "# promptLi: shadows Debian's debian.conf — keeps the console keymap\n\
             # instead of re-symlinking /etc/vconsole.conf to default/keyboard.\n\
             L /run/shm - - - - /dev/shm\n\
             d /run/sendsigs.omit.d 0755 root root -\n\
             d /run/lock 1777 root root -\n\
             L+ /etc/mtab - - - - ../proc/self/mounts\n\
             L+ /etc/default/locale - - - - ../locale.conf\n\
             f /etc/vconsole.conf 0644 root root - KEYMAP={keymap}\\nFONT=Lat2-Terminus16\\n\n"
        ),
    )?;
    Ok(())
}

/// Set the system timezone via /etc/localtime symlink + /etc/timezone.
fn write_timezone(root: &Path, tz: &str) -> io::Result<()> {
    let tz = tz.trim();
    if tz.is_empty() {
        return Ok(());
    }
    let zoneinfo = root.join("usr/share/zoneinfo").join(tz);
    if !zoneinfo.exists() {
        eprintln!("warning: unknown timezone {tz} — keeping UTC");
        return Ok(());
    }
    let _ = std::fs::remove_file(root.join("etc/localtime"));
    std::os::unix::fs::symlink(format!("/usr/share/zoneinfo/{tz}"), root.join("etc/localtime"))?;
    std::fs::write(root.join("etc/timezone"), format!("{tz}\n"))?;
    Ok(())
}

/// Enable the serial console on the installed system — promptLi OS is a
/// server distro, so ttyS0 (IPMI/headless/VPS consoles) should work out of
/// the box, alongside the regular VGA tty.
fn enable_serial_console(root: &Path) -> io::Result<()> {
    let grub_defaults = root.join("etc/default/grub");
    let mut content = std::fs::read_to_string(&grub_defaults).unwrap_or_default();

    fn ensure(content: &mut String, key: &str, value: &str) {
        let line = format!("{key}=\"{value}\"");
        let mut found = false;
        let mut out = String::new();
        for l in content.lines() {
            let trimmed = l.trim_start();
            let matched = trimmed.starts_with(key) && !trimmed.starts_with(&format!("{key}_"));
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

fn create_user(
    root: &Path,
    username: &str,
    password: &str,
    root_password: &str,
) -> io::Result<()> {
    // Use chroot + useradd + chpasswd. zsh is the promptLi default shell.
    let mut script = format!(
        "useradd -m -s /usr/bin/zsh -G sudo,netdev,video {u} 2>/dev/null || true; \
         echo '{u}:{p}' | chpasswd",
        u = username,
        p = password
    );
    if root_password.is_empty() {
        // Lock root (sudo via the primary user only).
        script.push_str("; passwd -l root 2>/dev/null || true");
    } else {
        script.push_str(&format!("; echo 'root:{rp}' | chpasswd", rp = root_password));
    }
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
