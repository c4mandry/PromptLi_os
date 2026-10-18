"""Encrypted API-key storage for AIDO.

The LLM API key (for a remote provider) is stored on the user's own device,
encrypted at rest with AES-256-GCM using `openssl` (present on every Debian
base, so no extra Python dependency). The ciphertext lives at
``/etc/aido/secrets.enc`` owned by ``root:root`` with mode ``0600``, and is
derived from a passphrase the user supplies at set-time.

Access model (enforced by filesystem permissions + the sudo gate in the CLI):

- **set**   ``sudo aido key set``      — prompt for the key + a passphrase.
- **show**  ``sudo aido key show``     — decrypt and print the key.
- **clear** ``sudo aido key clear``    — remove the stored key.

Reading the file without root fails (0600 root:root), so the plaintext key
cannot be recovered by an unprivileged process. The passphrase is derived
into an AES key with PBKDF2 (openssl enc -pbkdf2), and the key is never
written to disk in cleartext.
"""

from __future__ import annotations

import getpass
import shutil
import subprocess
import sys
from pathlib import Path

# Root-owned, mode 0600 — only readable via sudo.
SECRET_PATH = Path("/etc/aido/secrets.enc")

_SALT = b"promptli-aido-v1"


def _openssl() -> str:
    """Return the path to openssl, or raise with a friendly message."""
    path = shutil.which("openssl")
    if not path:
        raise RuntimeError("openssl is required but was not found on PATH.")
    return path


def _derive_key(passphrase: str) -> bytes:
    """PBKDF2 (SHA-256) key derivation from the passphrase."""
    import hashlib

    return hashlib.pbkdf2_hmac("sha256", passphrase.encode("utf-8"), _SALT, 200_000, dklen=32)


def _encrypt(plaintext: str, passphrase: str) -> bytes:
    import hmac as _hmac
    import hashlib as _hashlib
    import os as _os

    key = _derive_key(passphrase)
    # AES-256-CTR (openssl enc) + an HMAC-SHA256 in encrypt-then-MAC order,
    # so a wrong passphrase or tampered file fails the MAC check cleanly.
    # Layout: nonce(12) || mac(32) || ciphertext.
    nonce = _os.urandom(12)
    key_hex = key.hex()
    nonce_hex = nonce.hex()
    proc = subprocess.run(
        [
            _openssl(), "enc", "-aes-256-ctr",
            "-K", key_hex,
            "-iv", nonce_hex,
            "-nosalt",
        ],
        input=plaintext.encode("utf-8"),
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"openssl encrypt failed: {proc.stderr.decode().strip()}")
    ciphertext = proc.stdout
    mac = _hmac.new(key, nonce + ciphertext, _hashlib.sha256).digest()
    return nonce + mac + ciphertext


def _decrypt(ciphertext: bytes, passphrase: str) -> str:
    import hmac as _hmac
    import hashlib as _hashlib

    key = _derive_key(passphrase)
    if len(ciphertext) < 12 + 32:
        raise RuntimeError("corrupted key file.")
    nonce = ciphertext[:12]
    mac = ciphertext[12:44]
    data = ciphertext[44:]
    expected = _hmac.new(key, nonce + data, _hashlib.sha256).digest()
    if not _hmac.compare_digest(mac, expected):
        raise RuntimeError("decryption failed — wrong passphrase, or the key file was tampered with.")
    key_hex = key.hex()
    nonce_hex = nonce.hex()
    proc = subprocess.run(
        [
            _openssl(), "enc", "-d", "-aes-256-ctr",
            "-K", key_hex,
            "-iv", nonce_hex,
            "-nosalt",
        ],
        input=data,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError("decryption failed — wrong passphrase.")
    try:
        return proc.stdout.decode("utf-8")
    except UnicodeDecodeError:
        raise RuntimeError("decryption failed — wrong passphrase.") from None


def requires_root() -> bool:
    """True if the current process is running as root (euid 0)."""
    if hasattr(sys, "geteuid"):
        try:
            return sys.geteuid() == 0  # type: ignore[attr-defined]
        except AttributeError:
            pass
    proc = subprocess.run(["id", "-u"], capture_output=True, text=True)
    return proc.stdout.strip() == "0"


def key_set() -> int:
    """Prompt for an API key + passphrase, encrypt, and store (root-only)."""
    if not requires_root():
        print("error: setting the API key needs root. Re-run with: sudo aido key set", file=sys.stderr)
        return 1
    print("AIDO API key (remote model provider).")
    print("The key is encrypted with a passphrase you choose and stored as root.\n")
    key = getpass.getpass("API key: ").strip()
    if not key:
        print("error: empty key.", file=sys.stderr)
        return 1
    confirm = getpass.getpass("API key (again): ").strip()
    if key != confirm:
        print("error: keys did not match.", file=sys.stderr)
        return 1
    passphrase = getpass.getpass("Encryption passphrase (protects the key): ")
    if not passphrase:
        print("error: empty passphrase.", file=sys.stderr)
        return 1
    ciphertext = _encrypt(key, passphrase)
    SECRET_PATH.parent.mkdir(parents=True, exist_ok=True)
    SECRET_PATH.write_bytes(ciphertext)
    SECRET_PATH.chmod(0o600)
    print(f"✓ API key stored (encrypted) at {SECRET_PATH}")
    return 0


def key_show() -> int:
    """Decrypt and print the stored key (root-only)."""
    if not requires_root():
        print("error: reading the API key needs root. Re-run with: sudo aido key show", file=sys.stderr)
        return 1
    if not SECRET_PATH.is_file():
        print("no API key stored yet. Set one with: sudo aido key set", file=sys.stderr)
        return 1
    passphrase = getpass.getpass("Encryption passphrase: ")
    try:
        key = _decrypt(SECRET_PATH.read_bytes(), passphrase)
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(key)
    return 0


def key_clear() -> int:
    """Remove the stored key (root-only)."""
    if not requires_root():
        print("error: removing the API key needs root. Re-run with: sudo aido key clear", file=sys.stderr)
        return 1
    if SECRET_PATH.is_file():
        SECRET_PATH.unlink()
        print("✓ API key removed.")
    else:
        print("no API key stored.")
    return 0
