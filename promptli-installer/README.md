# promptLi Installer

A fast, minimal **Rust TUI installer + self-updater** for promptLi OS — a
server-focused, WM/DE-free Debian derivative.

Two commands ship from a single compiled binary (dispatch via `argv[0]`):

- **`promptli-install`** — interactive guided installer (archinstall-style):
  a numbered step menu (jump with number keys) with a live description +
  configuration summary panel, per-field edit screens, quick-pick lists for
  the console keymap and timezone, a review screen, and a live progress
  screen during the install. Works **fully offline** — the website callback
  is best-effort and never blocks.
- **`promptli-update`** — checks for / applies OS updates via apt
  (`--check`, `--apply`).

## Why Rust

- Compiles to a **single ~1.8 MB stripped binary** with no runtime deps
  (glibc only) — nothing extra to ship inside the ISO.
- Small memory footprint and fast startup, appropriate for a minimal OS.
- Low-level orchestration via proven system tools (`sfdisk`, `mkfs`,
  `mkswap`, `unsquashfs`, `grub-install`) — no reimplementing filesystem
  logic.

## Build

```bash
cargo build --release
# → target/release/promptli-install
```

Then copy it as `promptli-update` (or let the build script do it automatically):

```bash
cp target/release/promptli-install ../promptli-install
```

## Usage

Interactive (guided, offline):

```bash
sudo promptli-install
```

Unattended (scripted installs):

```bash
sudo promptli-install --disk sda --bios \
  --hostname mybox --user promptli --password hunter2 \
  --keymap fi --timezone Europe/Helsinki \
  --swap --site https://webnotes.work
```

## Website callback ("callback thinggies")

The installer talks to the promptLi OS distribution API on the website:

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/os/install` | Register a freshly-installed machine → returns an enrollment token |
| `GET` | `/api/os/latest` | Fetch the current release manifest (update check) |

The enrollment token + site URL are written to `/etc/promptli/install.json` on
the installed system, and `promptli-update` reads that file on every run.

## Installer behavior

1. **Discover disks** via `lsblk`, skip loop/cdrom, require ≥ 1 GiB.
2. **Partition** the chosen disk:
   - UEFI/GPT: 512M ESP + ext4 root (+ optional auto-sized swap)
   - BIOS/MBR: ext4 root (+ optional auto-sized swap)
   - Swap size: 1 GiB (<12G disk), 4 GiB (<32G), 8 GiB (≥32G)
3. **Extract** the live squashfs (`find_live_root`) into the target.
4. **Configure** hostname, `/etc/fstab` (by UUID, incl. swap), console
   keymap (`/etc/vconsole.conf` + `/etc/default/keyboard` + a tmpfiles.d
   override so Debian does not re-symlink vconsole.conf on boot), timezone
   (`/etc/localtime` symlink + `/etc/timezone`), user account (root locked
   by default or with `--root-password`).
5. **Install bootloader** (GRUB EFI or BIOS) via chroot.
6. **Enroll** with the website (best-effort — never blocks the install).
7. **Unmount** and report success.

## Interactive keys

| Key | Action |
|---|---|
| `↑`/`↓`, `j`/`k` | navigate |
| `1`-`9`, `0` | jump straight to a step |
| `Enter` | open / confirm / install |
| `h`, `Esc`, `←` | back to the menu |
| any character | type a custom value (keymap/timezone/name fields) |
| `q` | quit
