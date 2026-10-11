//! promptLi OS installer + updater — single binary, dispatched by argv[0] or subcommand.

mod common;
mod disk;
mod http_client;
mod install;
mod proc;
mod ui;
mod update;

use crate::install::{run_install, InstallOptions};
use std::path::PathBuf;

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
    let _apply = args.iter().any(|a| a == "--apply");
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
    // Parse simple flags.
    let mut disk_flag: Option<String> = None;
    let mut hostname = "promptli".to_string();
    let mut username = "promptli".to_string();
    let mut password = "promptli".to_string();
    let mut site_url = common::DEFAULT_SITE_URL.to_string();
    let mut layout = crate::disk::PartitionScheme::Efi;
    let mut from: Option<PathBuf> = None;
    let mut version = env_version();

    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        match a.as_str() {
            "--disk" => {
                disk_flag = args.get(i + 1).cloned();
                i += 1;
            }
            "--hostname" => {
                hostname = args.get(i + 1).cloned().unwrap_or(hostname);
                i += 1;
            }
            "--user" => {
                username = args.get(i + 1).cloned().unwrap_or(username);
                i += 1;
            }
            "--password" => {
                password = args.get(i + 1).cloned().unwrap_or(password);
                i += 1;
            }
            "--site" => {
                site_url = args.get(i + 1).cloned().unwrap_or(site_url);
                i += 1;
            }
            "--bios" => {
                layout = crate::disk::PartitionScheme::Bios;
            }
            "--efi" => {
                layout = crate::disk::PartitionScheme::Efi;
            }
            "--from" => {
                from = args.get(i + 1).map(PathBuf::from);
                i += 1;
            }
            "--version" => {
                version = args.get(i + 1).cloned().unwrap_or(version);
                i += 1;
            }
            "--help" | "-h" => {
                print_usage();
                return 0;
            }
            _ => {}
        }
        i += 1;
    }

    let _ = from;

    // Phase 1: choose a disk.
    let disk = match disk_flag {
        Some(d) => d,
        None => {
            let disks = match disk::discover_disks(1024 * 1024 * 1024) {
                Ok(d) => {
                    if d.is_empty() {
                        eprintln!("No suitable disks found.");
                        return 1;
                    }
                    d
                }
                Err(e) => {
                    eprintln!("Failed to discover disks: {e}");
                    return 1;
                }
            };
            match ui::run(disks) {
                Ok(Some(cfg)) => {
                    // Pull other options back out of the interactive config.
                    hostname = cfg.hostname;
                    username = cfg.username;
                    password = cfg.password;
                    site_url = cfg.site_url;
                    layout = cfg.layout;
                    cfg.disk
                }
                Ok(None) => {
                    eprintln!("Cancelled.");
                    return 0;
                }
                Err(e) => {
                    eprintln!("TUI error: {e}");
                    return 1;
                }
            }
        }
    };

    let opts = InstallOptions {
        disk,
        layout,
        hostname,
        username,
        password,
        site_url,
        version: version.clone(),
    };

    println!();
    println!("Installing promptLi OS v{version} ...");
    println!();

    match run_install(&opts, |step| ui::print_step(step)) {
        Ok(state) => {
            println!();
            println!("✅ Installation complete.");
            println!("   Hostname:  {}", opts.hostname);
            println!("   User:      {}", opts.username);
            if !state.token.is_empty() {
                println!("   Enrolled:  {} (token {})", state.site_url, &state.token[..state.token.len().min(12)]);
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
    std::env::var("PROMPTLI_VERSION").unwrap_or_else(|_| "1.0.0".to_string())
}

fn print_usage() {
    println!(
        "promptLi OS installer\n\n\
USAGE:\n\
  promptli-install                     Interactive TUI installer\n\
  promptli-install --disk sda [opts]   Unattended install\n\
  promptli-update (--check|--apply)    apt update/upgrade (same as pacman -Syu)\n\n\
OPTIONS:\n\
  --disk <dev>        Target disk (e.g. sda)\n\
  --hostname <name>   Hostname (default: promptli)\n\
  --user <user>       Username  (default: promptli)\n\
  --password <pass>   Password  (default: promptli)\n\
  --site <url>        Update/enrollment server (default: https://webnotes.work)\n\
  --efi | --bios      Partition layout (default: efi)\n\
  --version <ver>     Version to record\n\
  -h, --help          Show this help\n"
    );
}
