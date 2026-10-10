//! Disk discovery and partitioning.

use crate::common::Disk;
use crate::proc;
use std::io;
use std::path::Path;

/// Query block devices via lsblk and return candidate install targets:
/// whole disks of a reasonable minimum size, excluding the live medium itself.
pub fn discover_disks(min_bytes: u64) -> io::Result<Vec<Disk>> {
    let out = proc::run(
        "lsblk",
        &["-J", "-d", "-o", "NAME,SIZE,MODEL,TRAN,RM"],
    )?;
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).map_err(|e| {
        io::Error::new(io::ErrorKind::InvalidData, format!("bad lsblk output: {e}"))
    })?;

    let mut disks = Vec::new();
    if let Some(items) = json["blockdevices"].as_array() {
        for dev in items {
            let name = dev["name"].as_str().unwrap_or("").to_string();
            // Skip loop devices (the live squashfs sits on one) and sr*/cdrom.
            if name.starts_with("loop") || name.starts_with("sr") {
                continue;
            }
            let size_bytes = dev["size"]
                .as_str()
                .and_then(|s| s.parse::<u64>().ok())
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
    /// GPT with an ESP (EFI system partition) + root.
    Efi,
    /// MBR (BIOS) with a single root partition (bios_grub not used).
    Bios,
}

/// Partition the target disk.
///
/// For EFI/GPT: a 512M FAT32 ESP + the remainder as a single ext4 root.
/// For BIOS/MBR: the whole disk as a single ext4 root (bootable flag set).
pub fn partition_disk(disk: &Disk, layout: PartitionScheme, hostname: &str) -> io::Result<PartitionResult> {
    let dev = dev_path(&disk.name);

    // Wipe any existing partition table signature.
    let _ = proc::run("sgdisk", &["--zap-all", &dev]);
    let _ = proc::run("wipefs", &["--all", &dev]);

    match layout {
        PartitionScheme::Efi => {
            // GPT: [+512M FAT32 ESP][rest ext4 root]
            let esp = format!("{}{}", dev, if dev.ends_with("nvme") || dev.contains("mmcblk") { "p1" } else { "1" });
            let root = format!("{}{}", dev, if dev.ends_with("nvme") || dev.contains("mmcblk") { "p2" } else { "2" });

            let script = "label: gpt\n,512M,U,\n,,L\n";
            proc::run("sfdisk", &["--wipe", "always", &dev])?;
            // Write table via stdin.
            write_stdin("sfdisk", &[&dev], script)?;

            proc::run("mkfs.fat", &["-F32", "-n", "EFI", &esp])?;
            proc::run("mkfs.ext4", &["-F", "-L", hostname, &root])?;
            Ok(PartitionResult { layout, esp: Some(esp), root })
        }
        PartitionScheme::Bios => {
            let root = format!("{}{}", dev, if dev.contains("nvme") || dev.contains("mmcblk") { "p1" } else { "1" });
            let script = "label: dos\n,,L,*\n";
            write_stdin("sfdisk", &[&dev], script)?;
            proc::run("mkfs.ext4", &["-F", "-L", hostname, &root])?;
            Ok(PartitionResult { layout, esp: None, root })
        }
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
