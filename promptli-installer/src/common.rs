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

/// The running OS version: `PROMPTLI_VERSION` env (set at login via
/// /etc/profile.d/promptli-version.sh), falling back to /etc/os-release's
/// VERSION_ID so fastfetch and the installer agree on the same number.
pub fn distro_version() -> String {
    if let Ok(v) = std::env::var("PROMPTLI_VERSION") {
        if !v.trim().is_empty() {
            return v;
        }
    }
    if let Ok(release) = std::fs::read_to_string("/etc/os-release") {
        for line in release.lines() {
            if let Some(val) = line.strip_prefix("VERSION_ID=") {
                let v = val.trim().trim_matches('"');
                if !v.is_empty() {
                    return v.to_string();
                }
            }
        }
    }
    "1.0.0".to_string()
}

/// Compare two dotted `major.minor.patch` version strings.
/// Returns std::cmp::Ordering. Numeric comparison (so 1.10.0 > 1.9.0); any
/// non-numeric segment is treated as 0.
pub fn compare_version(a: &str, b: &str) -> std::cmp::Ordering {
    let parse = |v: &str| -> Vec<u64> {
        v.split('.')
            .map(|p| p.parse::<u64>().unwrap_or(0))
            .collect()
    };
    let va = parse(a);
    let vb = parse(b);
    let n = va.len().max(vb.len());
    for i in 0..n {
        let x = va.get(i).copied().unwrap_or(0);
        let y = vb.get(i).copied().unwrap_or(0);
        if x != y {
            return x.cmp(&y);
        }
    }
    std::cmp::Ordering::Equal
}

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

#[cfg(test)]
mod tests {
    use super::compare_version;

    #[test]
    fn version_ordering() {
        assert_eq!(compare_version("1.23.0", "1.23.0"), std::cmp::Ordering::Equal);
        assert_eq!(compare_version("1.24.0", "1.23.3"), std::cmp::Ordering::Greater);
        assert_eq!(compare_version("1.9.0", "1.10.0"), std::cmp::Ordering::Less);
        assert_eq!(compare_version("2.0.0", "1.99.99"), std::cmp::Ordering::Greater);
        assert_eq!(compare_version("1.23.3", "1.23.10"), std::cmp::Ordering::Less);
    }
}
