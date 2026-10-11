//! Shared constants and types for the promptLi OS installer + updater.

use serde::{Deserialize, Serialize};

/// Where the live ISO mounts its read-only squashfs filesystem.
/// live-boot exposes the boot medium under /run/live/medium, and the
/// compressed root at /run/live/rootfs (or /lib/live/mount/rootfs).
pub const LIVE_SQUASHFS_PATHS: &[&str] = &[
    "/run/live/medium/live/filesystem.squashfs",
    "/lib/live/mount/medium/live/filesystem.squashfs",
    "/run/live/rootfs",
    "/lib/live/mount/rootfs",
    // Fallback: the installer may have been given the path directly.
];

/// Default website base URL used for enrollment.
pub const DEFAULT_SITE_URL: &str = "https://webnotes.work";

/// Machine state written onto the installed system after a successful install.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstallState {
    /// promptLi OS version that was installed.
    pub version: String,
    /// Base URL of the website (enrollment callback host).
    pub site_url: String,
    /// Enrollment token issued by the server on registration.
    pub token: String,
    /// Machine identifier (hostname + random machine-id).
    pub machine_id: String,
    /// Install timestamp (RFC3339).
    pub installed_at: String,
}

/// A disk as discovered via lsblk.
#[derive(Debug, Clone)]
pub struct Disk {
    pub name: String,
    pub size_bytes: u64,
    pub model: String,
    pub removable: bool,
}

impl Disk {
    pub fn size_human(&self) -> String {
        let mut v = self.size_bytes as f64;
        let units = ["B", "KB", "MB", "GB", "TB"];
        let mut i = 0;
        while v >= 1024.0 && i < units.len() - 1 {
            v /= 1024.0;
            i += 1;
        }
        if i == 0 {
            format!("{:.0} {}", v, units[i])
        } else {
            format!("{:.1} {}", v, units[i])
        }
    }
}
