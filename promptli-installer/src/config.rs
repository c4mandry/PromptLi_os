//! Installer configuration: the fully-resolved values the wizard produces and
//! the install step consumes. This is the single source of truth shared between
//! the interactive TUI and the non-interactive `--<flag>` path.

use crate::disk::PartitionScheme;

/// Everything the installer needs to know about the incoming machine.
#[derive(Debug, Clone)]
pub struct Config {
    /// Target disk name (e.g. "sda", "nvme0n1"). Empty = not chosen yet.
    pub disk: String,
    /// Partition layout: UEFI/GPT or BIOS/MBR.
    pub layout: PartitionScheme,
    /// Create a swap partition? (auto-sized; skipped on tiny disks)
    pub swap: bool,
    /// Hostname.
    pub hostname: String,
    /// Primary user account name.
    pub username: String,
    /// Primary user password (cleartext; written via chpasswd).
    pub password: String,
    /// Root password (empty = same as user / locked sudo).
    pub root_password: String,
    /// Console keymap (e.g. "et", "us", "fi").
    pub keymap: String,
    /// System timezone (e.g. "Europe/Tallinn").
    pub timezone: String,
    /// Enrollment site URL.
    pub site_url: String,
    /// Set when the interactive TUI has run the install (success or not).
    pub installed: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            disk: String::new(),
            layout: PartitionScheme::Efi,
            swap: true,
            hostname: "promptli".to_string(),
            username: "promptli".to_string(),
            password: "promptli".to_string(),
            root_password: String::new(),
            keymap: "et".to_string(),
            timezone: "Europe/Tallinn".to_string(),
            site_url: crate::common::DEFAULT_SITE_URL.to_string(),
            installed: false,
        }
    }
}

/// Summary line for a single setting, shown on the review screen and in the
/// side panel of the main menu.
pub fn summary_rows(c: &Config) -> Vec<(String, String)> {
    let layout = match c.layout {
        PartitionScheme::Efi => "UEFI  (GPT: ESP + root)".to_string(),
        PartitionScheme::Bios => "BIOS   (MBR: root [+ swap])".to_string(),
    };
    let swap = if c.swap { "auto-sized (yes)" } else { "none" };
    let root_pw = if c.root_password.is_empty() {
        "disabled (sudo via user)".to_string()
    } else {
        "set".to_string()
    };
    vec![
        ("Disk".to_string(), c.disk.clone()),
        ("Partitioning".to_string(), layout),
        ("Swap".to_string(), swap.to_string()),
        ("Hostname".to_string(), c.hostname.clone()),
        ("User".to_string(), c.username.clone()),
        ("Root password".to_string(), root_pw),
        ("Keymap".to_string(), c.keymap.clone()),
        ("Timezone".to_string(), c.timezone.clone()),
        ("Update server".to_string(), c.site_url.clone()),
    ]
}
