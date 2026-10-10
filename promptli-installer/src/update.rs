//! The `promptli-update` subcommand: check for / apply OS updates from the website.

use crate::common::InstallState;
use crate::http_client;

pub fn run_check(state: Option<InstallState>) -> std::io::Result<i32> {
    let Some(state) = state else {
        eprintln!("promptli-update: not installed (missing {})", crate::common::INSTALL_STATE_PATH);
        return Ok(1);
    };

    match http_client::check_update(&state.site_url, Some(&state.token), &state.version) {
        Ok(Some(m)) => {
            println!(
                "A new promptLi OS release is available: {} -> {}{}",
                state.version,
                m.version.as_deref().unwrap_or("unknown"),
                m.released_at
                    .as_deref()
                    .map(|d| format!(" (released {d})"))
                    .unwrap_or_default()
            );
            if let Some(url) = &m.iso_url {
                println!("Download: {}{}", state.site_url, url);
            }
            Ok(0)
        }
        Ok(None) => {
            println!("promptLi OS is up to date (v{}).", state.version);
            Ok(0)
        }
        Err(e) => {
            eprintln!("promptli-update: check failed: {e}");
            Ok(1)
        }
    }
}

pub fn run_apply(state: Option<InstallState>, dest: &str) -> std::io::Result<i32> {
    let Some(state) = state else {
        eprintln!("promptli-update: not installed (missing {})", crate::common::INSTALL_STATE_PATH);
        return Ok(1);
    };

    let manifest = match http_client::fetch_latest(&state.site_url, Some(&state.token)) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("promptli-update: fetch failed: {e}");
            return Ok(1);
        }
    };

    let url = match manifest.iso_url.as_deref() {
        Some(u) if !u.is_empty() => u,
        _ => {
            eprintln!("promptli-update: no download URL in manifest");
            return Ok(1);
        }
    };

    println!("Downloading promptLi OS {} ...", manifest.version.as_deref().unwrap_or("?"));
    http_client::download_iso(&state.site_url, url, dest)?;
    println!("Saved to {dest}. Reflash to install or run `promptli-install --from {dest}`.");
    Ok(0)
}
