//! HTTP client for website enrollment (the one callback still needed).
//!
//! Uses `ureq` with rustls so there is no OpenSSL system dependency — the
//! installer binary stays minimal. (System updates now go through apt/pacman,
//! so the old ISO-download helpers were removed.)

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

fn trim_slash(s: &str) -> &str {
    s.trim_end_matches('/')
}

/// GET /api/os/latest → the release manifest (version, iso_url, sha256, …).
/// Returns the parsed JSON, or None if the endpoint is unreachable/missing.
pub fn fetch_latest(site_url: &str) -> Option<serde_json::Value> {
    let resp = ureq::get(&format!("{}/api/os/latest", trim_slash(site_url)))
        .set("Accept", "application/json")
        .call()
        .ok()?;
    if resp.status() != 200 {
        return None;
    }
    resp.into_json::<serde_json::Value>().ok()
}
