//! promptLi OS installer + updater — single binary, dispatched by argv[0] or subcommand.
//!
//! Interactive: `promptli-install` (guided archinstall-style TUI, works offline).
//! Unattended:  `promptli-install --disk vda [flags]`.

mod common;
mod config;
mod disk;
mod http_client;
mod install;
mod proc;
mod ui;
mod update;

use crate::config::Config;
use crate::install::InstallOptions;

fn main() {
    let argv0 = std::env::args().next().unwrap_or_default();
    let invoked_as_update = argv0.contains("promptli-update");

    let args: Vec<String> = std::env::args().skip(1).collect();

    if invoked_as_update {
        std::process::exit(run_update(&args));
    }

    // First arg may be a subcommand (install/update) for clarity.
    match args.first().map(|s| s.as_str()) {
        Some("update") | Some("--update") => std::process::exit(run_update(&args[1..])),
        _ => std::process::exit(run_installer(&args)),
    }
}

fn run_update(args: &[String]) -> i32 {
    // promptLi OS updates via the package managers; this is a friendly alias.
    let check = args.iter().any(|a| a == "--check");

    let res = if check {
        update::run_check(None)
    } else {
        update::run_apply(None, "")
    };

    match res {
        Ok(code) => code,
        Err(e) => {
            eprintln!("error: {e}");
            1
        }
    }
}

fn run_installer(args: &[String]) -> i32 {
    let mut cfg = Config::default();
    let mut disk_flag: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        let next = || args.get(i + 1).cloned();
        match a.as_str() {
            "--disk" => {
                disk_flag = next();
                i += 1;
            }
            "--hostname" => {
                if let Some(v) = next() {
                    cfg.hostname = v;
                }
                i += 1;
            }
            "--user" => {
                if let Some(v) = next() {
                    cfg.username = v;
                }
                i += 1;
            }
            "--password" => {
                if let Some(v) = next() {
                    cfg.password = v;
                }
                i += 1;
            }
            "--root-password" => {
                if let Some(v) = next() {
                    cfg.root_password = v;
                }
                i += 1;
            }
            "--keymap" => {
                if let Some(v) = next() {
                    cfg.keymap = v.to_ascii_lowercase();
                }
                i += 1;
            }
            "--timezone" => {
                if let Some(v) = next() {
                    cfg.timezone = v;
                }
                i += 1;
            }
            "--site" => {
                if let Some(v) = next() {
                    cfg.site_url = v;
                }
                i += 1;
            }
            "--swap" => {
                cfg.swap = true;
            }
            "--no-swap" => {
                cfg.swap = false;
            }
            "--bios" => {
                cfg.layout = crate::disk::PartitionScheme::Bios;
            }
            "--efi" => {
                cfg.layout = crate::disk::PartitionScheme::Efi;
            }
            "--version" => {
                i += 1; // accepted for compatibility; version comes from env
            }
            "--help" | "-h" => {
                print_usage();
                return 0;
            }
            _ => {}
        }
        i += 1;
    }

    // ── Interactive: guided TUI ──
    if disk_flag.is_none() {
        let disks = match disk::discover_disks(1024 * 1024 * 1024) {
            Ok(d) => d,
            Err(e) => {
                eprintln!("Failed to discover disks: {e}");
                return 1;
            }
        };
        if disks.is_empty() {
            eprintln!("No suitable disks found (need ≥1 GB, non-loop).");
            return 1;
        }
        return match ui::run(disks) {
            Ok(Some(final_cfg)) => {
                // The TUI runs the install itself and shows the result on its
                // Done screen — never run it a second time here.
                if final_cfg.installed {
                    0
                } else {
                    eprintln!("Installation did not complete.");
                    1
                }
            }
            Ok(None) => {
                eprintln!("Cancelled.");
                0
            }
            Err(e) => {
                eprintln!("TUI error: {e}");
                1
            }
        };
    }

    // ── Unattended: flags fully describe the install ──
    cfg.disk = disk_flag.unwrap_or_default();
    install_and_report(&cfg)
}

fn install_and_report(cfg: &Config) -> i32 {
    let opts = InstallOptions {
        disk: cfg.disk.clone(),
        layout: cfg.layout,
        swap: cfg.swap,
        hostname: cfg.hostname.clone(),
        username: cfg.username.clone(),
        password: cfg.password.clone(),
        root_password: cfg.root_password.clone(),
        keymap: cfg.keymap.clone(),
        timezone: cfg.timezone.clone(),
        site_url: cfg.site_url.clone(),
        version: env_version(),
    };

    println!();
    println!("Installing promptLi OS v{} ...", opts.version);
    println!();

    match install::run_install(&opts, ui::print_step) {
        Ok(state) => {
            println!();
            println!("✅ Installation complete.");
            println!("   Hostname:  {}", opts.hostname);
            println!("   User:      {}", opts.username);
            if !state.token.is_empty() {
                println!(
                    "   Enrolled:  {} (token {})",
                    state.site_url,
                    &state.token[..state.token.len().min(12)]
                );
            }
            println!();
            println!("Remove the install medium and reboot.");
            0
        }
        Err(e) => {
            eprintln!("❌ Installation failed: {e}");
            1
        }
    }
}

fn env_version() -> String {
    crate::common::distro_version()
}

fn print_usage() {
    println!(
        "promptLi OS installer\n\n\
USAGE:\n\
  promptli-install                     Interactive guided TUI (offline)\n\
  promptli-install --disk sda [opts]   Unattended install\n\
  promptli-update (--check|--apply)    apt update/upgrade (same as pacman -Syu)\n\n\
OPTIONS:\n\
  --disk <dev>         Target disk (e.g. sda)\n\
  --hostname <name>    Hostname (default: promptli)\n\
  --user <user>        Username  (default: promptli)\n\
  --password <pass>    User password (default: promptli)\n\
  --root-password <p>  Root password (default: root login disabled)\n\
  --keymap <layout>    Console keymap: et, us, fi, de, … (default: et)\n\
  --timezone <tz>      e.g. Europe/Tallinn (default: Europe/Tallinn)\n\
  --site <url>         Enrollment server (default: https://webnotes.work)\n\
  --swap | --no-swap   Create a swap partition (default: swap on)\n\
  --efi | --bios       Partition layout (default: efi)\n\
  --version <ver>      Version to record\n\
  -h, --help           Show this help\n"
    );
}
