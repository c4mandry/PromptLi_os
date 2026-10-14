//! Disk discovery and partitioning.

use crate::common::Disk;
use crate::proc;
use std::io;
use std::path::Path;

/// Parse a human-readable size from lsblk ("8G", "930M", "512K") into bytes.
fn parse_size(s: &str) -> u64 {
    let s = s.trim();
    if s.is_empty() {
        return 0;
    }
    // Plain number = bytes.
    if let Ok(v) = s.parse::<u64>() {
        return v;
    }
    let (num, suffix) = s.split_at(s.len() - 1);
    let mult: u64 = match suffix {
        "K" => 1 << 10,
        "M" => 1 << 20,
        "G" => 1 << 30,
        "T" => 1 << 40,
        "P" => 1 << 50,
        _ => 1,
    };
    num.trim().parse::<f64>().map(|v| (v * mult as f64) as u64).unwrap_or(0)
}

/// Query block devices via lsblk and return candidate install targets:
/// whole disks of a reasonable minimum size, excluding the live medium itself.
pub fn discover_disks(min_bytes: u64) -> io::Result<Vec<Disk>> {
    let out = proc::run(
        "lsblk",
        &["-J", "-b", "-d", "-o", "NAME,SIZE,MODEL,TRAN,RM"],
    )?;
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).map_err(|e| {
        io::Error::new(io::ErrorKind::InvalidData, format!("bad lsblk output: {e}"))
    })?;

    let mut disks = Vec::new();
    if let Some(items) = json["blockdevices"].as_array() {
        for dev in items {
            let name = dev["name"].as_str().unwrap_or("").to_string();
            // Skip loop devices (the live squashfs sits on one), fd/floppy,
            // and sr*/cdrom.
            if name.starts_with("loop") || name.starts_with("sr") || name.starts_with("fd") {
                continue;
            }
            let size_bytes = dev["size"]
                .as_str()
                .map(parse_size)
                .or_else(|| dev["size"].as_u64())
                .unwrap_or(0);
            if size_bytes < min_bytes {
                continue;
            }
            disks.push(Disk {
                name,
                size_bytes,
                model: dev["model"].as_str().unwrap_or("").to_string(),
                removable: dev["rm"].as_bool().unwrap_or(false),
            });
        }
    }
    Ok(disks)
}

/// The device path for a disk name, e.g. "sda" -> "/dev/sda".
pub fn dev_path(name: &str) -> String {
    if name.starts_with('/') {
        name.to_string()
    } else {
        format!("/dev/{name}")
    }
}

/// Partition layout we produce.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PartitionScheme {
    /// GPT with an ESP (EFI system partition) + root (+ optional swap).
    Efi,
    /// MBR (BIOS) with a single root partition (+ optional swap).
    Bios,
}

/// Partition a disk. `hostname` is used as the ext4 label; `swap` adds an
/// auto-sized swap partition (skipped when the disk is too small).
pub fn partition_disk(
    disk: &Disk,
    layout: PartitionScheme,
    hostname: &str,
    swap: bool,
) -> io::Result<PartitionResult> {
    let dev = dev_path(&disk.name);

    // Wipe any existing partition table signature.
    let _ = proc::run("sgdisk", &["--zap-all", &dev]);
    let _ = proc::run("wipefs", &["--all", &dev]);

    let swap_mb = if swap { swap_size_mb(disk.size_bytes) } else { None };

    // Partition numbering helper: nvme/mmcblk use a `p` before the index.
    let part = |n: usize| {
        if dev.contains("nvme") || dev.contains("mmcblk") {
            format!("{dev}p{n}")
        } else {
            format!("{dev}{n}")
        }
    };

    match layout {
        PartitionScheme::Efi => {
            let esp = part(1);
            let (root, swap_dev) = if swap_mb.is_some() { (part(3), Some(part(2))) } else { (part(2), None) };
            let script = match swap_mb {
                Some(mb) => format!("label: gpt\n,512M,U,\n,{mb}M,S,\n,,L\n"),
                None => "label: gpt\n,512M,U,\n,,L\n".to_string(),
            };
            // (sgdisk --zap-all + wipefs --all above already cleaned the
            // disk; sfdisk itself creates the fresh GPT with the script.)
            write_stdin("sfdisk", &[&dev], &script)?;

            proc::run("mkfs.fat", &["-F32", "-n", "EFI", &esp])?;
            proc::run("mkfs.ext4", &["-F", "-L", hostname, &root])?;
            if let Some(sd) = &swap_dev {
                proc::run("mkswap", &["-f", sd])?;
            }
            Ok(PartitionResult { layout, esp: Some(esp), root, swap: swap_dev })
        }
        PartitionScheme::Bios => {
            // Swap FIRST, then root fills the rest (root must be last when
            // it uses the "rest of the disk" size). Boot flag on the root.
            let (root, swap_dev) = match swap_mb {
                Some(_) => (part(2), Some(part(1))),
                None => (part(1), None),
            };
            let script = match swap_mb {
                Some(mb) => format!("label: dos\n,{mb}M,S,\n,,L,*\n"),
                None => "label: dos\n,,L,*\n".to_string(),
            };
            write_stdin("sfdisk", &[&dev], &script)?;
            proc::run("mkfs.ext4", &["-F", "-L", hostname, &root])?;
            if let Some(sd) = &swap_dev {
                proc::run("mkswap", &["-f", sd])?;
            }
            Ok(PartitionResult { layout, esp: None, root, swap: swap_dev })
        }
    }
}

/// Auto swap sizing: 1G under 12G disk, 4G under 32G, 8G above. Returns
/// MiB, or None when the disk is too small for a meaningful swap.
fn swap_size_mb(disk_bytes: u64) -> Option<u64> {
    let gib = disk_bytes / (1 << 30);
    if gib >= 32 {
        Some(8 * 1024)
    } else if gib >= 12 {
        Some(4 * 1024)
    } else if gib >= 6 {
        Some(1024)
    } else {
        None
    }
}

fn write_stdin(cmd: &str, args: &[&str], input: &str) -> io::Result<()> {
    use std::io::Write;
    use std::process::{Command, Stdio};
    let mut child = Command::new(cmd)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()?;
    {
        let sin = child.stdin.as_mut().expect("piped stdin");
        sin.write_all(input.as_bytes())?;
    }
    let out = child.wait_with_output()?;
    if !out.status.success() {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!(
                "`{} {}` failed: {}",
                cmd,
                args.join(" "),
                String::from_utf8_lossy(&out.stderr).trim()
            ),
        ));
    }
    Ok(())
}

#[derive(Debug, Clone)]
pub struct PartitionResult {
    pub layout: PartitionScheme,
    pub esp: Option<String>,
    pub root: String,
    pub swap: Option<String>,
}

/// Mount a filesystem at `mountpoint` (creating the dir).
pub fn mount(src: &str, dst: &Path) -> io::Result<()> {
    std::fs::create_dir_all(dst)?;
    proc::run("mount", &[src, dst.to_str().unwrap_or("")])?;
    Ok(())
}

pub fn umount(dst: &Path) {
    let _ = proc::run("umount", &[dst.to_str().unwrap_or("")]);
}
