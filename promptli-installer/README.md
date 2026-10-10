# promptLi Installer

A fast, minimal **Rust TUI installer + self-updater** for promptLi OS — a
server-focused, WM/DE-free Debian derivative.

Two commands ship from a single compiled binary (dispatch via `argv[0]`):

- **`promptli-install`** — interactive terminal installer. Lists disks,
  partitions (UEFI/GPT by default, BIOS/MBR optional), extracts the live
  filesystem, installs GRUB, writes `/etc/fstab`, creates the user, and
  registers the machine with the website.
- **`promptli-update`** — checks for / applies OS updates from the website
  (`--check`, `--apply`).

## Why Rust

- Compiles to a **single ~1.7 MB stripped binary** with no runtime deps
  (glibc only) — nothing extra to ship inside the ISO.
- Small memory footprint and fast startup, appropriate for a minimal OS.
- Low-level orchestration via proven system tools (`sfdisk`, `mkfs`,
  `unsquashfs`, `grub-install`) — no reimplementing filesystem logic.

## Build

```bash
cargo build --release
# → target/release/promptli-install
```

Then copy it as `promptli-update` (or let the build script do it automatically):

```bash
cp target/release/promptli-install ../promptli-install
```

## Website callback ("callback thinggies")

The installer talks to the promptLi OS distribution API on the website:

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/os/install` | Register a freshly-installed machine → returns an enrollment token |
| `GET` | `/api/os/latest` | Fetch the current release manifest (update check) |
| `GET` | `/api/os/latest?token=…` | Same, and records a check-in |

The enrollment token + site URL are written to `/etc/promptli/install.json` on
the installed system, and `promptli-update` reads that file on every run.

## Installer behavior

1. **Discover disks** via `lsblk`, skip loop/cdrom, require ≥ 1 GiB.
2. **Partition** the chosen disk: GPT (512M ESP + ext4 root) or MBR (single root).
3. **Extract** the live squashfs (`find_live_root`) into the target.
4. **Configure** hostname, `/etc/fstab` (by UUID), user account.
5. **Install bootloader** (GRUB EFI or BIOS) via chroot.
6. **Enroll** with the website (best-effort — never blocks the install).
7. **Unmount** and report success.
