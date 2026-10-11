//! The `promptli-update` command: a thin friendly wrapper over the real
//! package managers. promptLi OS updates through `apt` (and `pacman`, which
//! the wrapper maps to apt) — there is no separate ISO-download mechanism.
//!
//!   promptli-update --check   → apt-get update; report what's upgradable
//!   promptli-update --apply   → apt-get upgrade -y (the actual OS update)

use crate::proc;

fn run_apt(args: &[&str]) -> std::io::Result<i32> {
    let code = proc::run_streaming("apt-get", args)?;
    Ok(code)
}

pub fn run_check(_state: Option<crate::common::InstallState>) -> std::io::Result<i32> {
    println!("Checking for package updates (apt-get update) ...");
    let code = run_apt(&["update"])?;
    if code != 0 {
        return Ok(code);
    }

    // Count upgradable packages without committing anything.
    let out = proc::run_capture_combined(
        "sh",
        &[
            "-c",
            "apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' || true",
        ],
    );
    let count = out.trim();
    if let Ok(n) = count.parse::<u32>() {
        if n > 0 {
            println!("{n} package(s) can be upgraded. Run `sudo apt upgrade` or `sudo pacman -Syu`.");
        } else {
            println!("promptLi OS is up to date.");
        }
    }
    Ok(0)
}

pub fn run_apply(_state: Option<crate::common::InstallState>, _dest: &str) -> std::io::Result<i32> {
    println!("Updating promptLi OS (apt-get upgrade) ...");
    let code = run_apt(&["upgrade", "-y"])?;
    if code == 0 {
        println!("✅ promptLi OS updated. Reboot if the kernel was upgraded.");
    }
    Ok(code)
}
