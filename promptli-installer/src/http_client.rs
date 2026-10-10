//! HTTP client for website enrollment + update checks (callback channel).
//!
//! Uses `ureq` with rustls so there is no OpenSSL system dependency — the
//! installer/updater binary stays fully static and minimal.

use crate::common::{InstallState, ReleaseManifest};
use crate::proc;
use serde_json::json;
use std::io;

/// POST /api/os/install -> enroll a machine, returning its token.
pub fn enroll(site_url: &str, version: &str, hostname: &str, machine_id: &str) -> io::Result<String> {
    let body = json!({
        "version": version,
        "hostname": hostname,
        "machine_id": machine_id,
    });

    let resp = ureq::post(&format!("{}/api/os/install", trim_slash(site_url)))
        .set("Content-Type", "application/json")
        .send_json(body)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;

    let code = resp.status();
    if !(200..300).contains(&code) {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!("enrollment HTTP {code}"),
        ));
    }

    let parsed: serde_json::Value = resp
        .into_json()
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;
    Ok(parsed["token"].as_str().unwrap_or("").to_string())
}

/// GET /api/os/latest[?token=...] -> current release manifest.
pub fn fetch_latest(site_url: &str, token: Option<&str>) -> io::Result<ReleaseManifest> {
    let url = match token {
        Some(t) if !t.is_empty() => format!("{}/api/os/latest?token={}", trim_slash(site_url), t),
        _ => format!("{}/api/os/latest", trim_slash(site_url)),
    };
    let resp = ureq::get(&url)
        .call()
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;
    if resp.status() != 200 {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!("HTTP {}", resp.status()),
        ));
    }
    resp.into_json()
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))
}

/// Load the machine's install state from disk.
pub fn load_state() -> Option<InstallState> {
    let raw = std::fs::read_to_string(crate::common::INSTALL_STATE_PATH).ok()?;
    serde_json::from_str(&raw).ok()
}

/// Check for an update and report it. Returns Some(manifest) if newer.
pub fn check_update(site_url: &str, token: Option<&str>, current: &str) -> io::Result<Option<ReleaseManifest>> {
    let manifest = fetch_latest(site_url, token)?;
    let latest = manifest.version.clone().unwrap_or_default();
    if latest.is_empty() || latest == current {
        return Ok(None);
    }
    Ok(Some(manifest))
}

/// Download the ISO/update to a path (used by `promptli-update --apply`).
pub fn download_iso(site_url: &str, url: &str, dest: &str) -> io::Result<()> {
    let full = if url.starts_with("http") {
        url.to_string()
    } else {
        format!("{}{}", trim_slash(site_url), url)
    };
    let mut reader = ureq::get(&full)
        .call()
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?
        .into_reader();
    let mut file = std::fs::File::create(dest)?;
    std::io::copy(&mut reader, &mut file)?;
    Ok(())
}

fn trim_slash(s: &str) -> &str {
    s.trim_end_matches('/')
}

#[allow(dead_code)]
fn _unused() {
    // keep proc import if unused in some cfg
    let _ = proc::has;
}
