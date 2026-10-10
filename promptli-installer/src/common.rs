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

/// Default website base URL used for enrollment + updates.
pub const DEFAULT_SITE_URL: &str = "https://webnotes.work";

/// Where installed machines store their enrollment + site config.
pub const INSTALL_STATE_PATH: &str = "/etc/promptli/install.json";

/// Machine state written onto the installed system after a successful install.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstallState {
    /// promptLi OS version that was installed.
    pub version: String,
    /// Base URL of the website (update + enrollment callback host).
    pub site_url: String,
    /// Enrollment token issued by the server on registration.
    pub token: String,
    /// Machine identifier (hostname + random machine-id).
    pub machine_id: String,
    /// Install timestamp (RFC3339).
    pub installed_at: String,
}

/// The release manifest published by the website at /api/os/latest.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReleaseManifest {
    pub name: Option<String>,
    pub version: Option<String>,
    pub codename: Option<String>,
    pub base: Option<String>,
    pub arch: Option<String>,
    #[serde(rename = "iso_filename")]
    pub iso_filename: Option<String>,
    #[serde(rename = "iso_url")]
    pub iso_url: Option<String>,
    pub sha256: Option<String>,
    #[serde(rename = "size_bytes")]
    pub size_bytes: Option<u64>,
    #[serde(rename = "released_at")]
    pub released_at: Option<String>,
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
