# promptLi OS — Complete Project Handoff

> **Audience:** the next AI (or developer) taking over this project.
> **Last updated:** 2026-11-01, at release **1.29.1**.
> **Read this whole document before touching anything.** It explains what the
> project is, how every moving part works, where things live, how to build,
> test and ship, and the traps that have already cost previous sessions hours.

---

## 1. TL;DR — what this project is

**promptLi OS** is a minimal, server-focused Linux distribution built on
**Debian 13 "trixie"**. It ships:

- **No desktop environment and no window manager.** It boots to a plain Linux
  console on `tty1` (and serial). There is no Xorg, Wayland, or display
  manager anywhere in the image — display managers are explicitly purged at
  build time.
- A **Rust TUI installer** (`promptli-install`) modelled on `archinstall`,
  fully offline, that partitions the disk, unpacks the live filesystem, sets
  up users, drivers, bootloader and the update layer.
- **AUR compatibility on Debian**: a `pacman` wrapper maps normal packages to
  `apt` and builds AUR packages with `makedeb`/`mist`. `pacman -Syu` performs
  a full system update, including the promptLi release layer.
- **`aido`**, a local (offline-capable) AI assistant that runs in the
  terminal, with 35 tools that can manipulate files, packages, services and
  the network — optionally with root privileges.
- **A custom performance kernel** (`6.12.115-promptli`) with the **BORE**
  scheduler, full preemption, HZ=1000, `-march=x86-64-v3`, BBR, MGLRU,
  zswap/zstd and an aggressive hardening set (see §12).
- **A website** (`webnotes.work`) that distributes the ISO, hosts the install
  docs, receives enrollment callbacks from the installer, and serves the
  update manifest that installed machines poll.

The current release is **1.29.1**, published as:

- `https://webnotes.work/os` (download page) and
  `https://webnotes.work/api/os/iso` (the ISO binary, public, no login).
- GitHub release `c4mandry/PromptLi_os` tag `v1.29.1`, with the ISO **and**
  the kernel `.deb` packages as assets.

Default live credentials: **`promptli` / `promptli`**. Root is **locked** by
default unless the installer sets a root password.

> **Where the source code lives (canonical, use only these):**
>
> | What | Absolute path | Git remote |
> |---|---|---|
> | OS (build script, installer, aido, kernel, docs) | `/home/ufi/promptlix/PromptLi_os` | `github.com/c4mandry/PromptLi_os` |
> | Website + distribution API | `/home/ufi/Documents/v3.1/cont/v3.1` | `github.com/c4mandry/insight-inweave` |
>
> Nothing else is source. `PromptLi_os/promptli-os/` (lowercase-hyphen) and
> `Readme.md`/`CONTEXT_FOR_X64.md` are **legacy and unused**. Build artifacts
> (`output/`, `promptli-installer/target/`, `__pycache__/`) are deliberately
> untracked — they are generated and published through the website and GitHub
> Release assets, never committed.

---

## 2. Product philosophy (this drives every design decision)

The user (Robert, GitHub `c4mandry`) wants a **fast, modern, bloat-free
server OS** that is pleasant to use from a terminal. Concretely, decisions
must follow these rules:

1. **Server-first, console-only.** No GUI. No i3, no GNOME, no Xorg. The
   "desktop" is a terminal. Anything GUI-related is bloat and gets removed.
2. **Fast boot, low idle RAM.** Mask unnecessary systemd units, cap journald,
   use `systemd-networkd` + `systemd-resolved` instead of NetworkManager,
   replace the dbus daemon with `dbus-broker`, keep one or two gettys.
3. **Modern but minimal.** zsh + Oh My Zsh + starship, `fastfetch` with a
   custom braille logo, modern coreutils replacements (eza, bat, ripgrep, fd,
   zoxide, btop, tmux), but none of it required for the system to work.
4. **AUR support is a headline feature.** The user explicitly asked for
   "AUR package support" even at the cost of reworking the base. The current
   approach is a pacman-compatible wrapper over apt + makedeb, not a real
   Arch base.
5. **Root-cause fixes.** Previous sessions were punished for superficial
   patches (e.g. login failing due to keymap/PAM interactions). Diagnose,
   then fix the actual mechanism.
6. **Ship it.** The user wants working ISOs on the website, with version
   numbers, GitHub releases and release notes — not just code in a repo.

---

## 3. Repository layout

There are **two repositories**. They are independent git repos with different
remotes and they must both be committed/pushed for a release.

### 3.1 OS repo — `/home/ufi/promptlix/PromptLi_os`

Remote: `https://github.com/c4mandry/PromptLi_os.git` (branch `main`).

```
PromptLi_os/
├── build_promptli.sh          # THE ISO BUILDER (bash, ~1400 lines)
├── aido/                      # AI assistant source (Python)
│   ├── src/{aido,agent,repl,tui,tools,secrets,session,roles,utils}.py
│   ├── config/aido.yaml
│   ├── roles/{coder.md,shell.md}
│   ├── tests/                 # pytest suite (82 passing)
│   ├── requirements.txt
│   └── setup.py
├── promptli-installer/        # Rust installer + updater (cargo)
│   ├── src/{main,ui,install,update,disk,config,common,proc,http_client}.rs
│   ├── Cargo.toml / Cargo.lock
│   └── README.md
├── kernel/                    # performance kernel project (new in 1.29.0)
│   ├── build_kernel.sh        # download → patch → configure → build .debs
│   ├── promptli-kernel.config # the exact .config used for 6.12.115-promptli
│   ├── SECURITY-AUDIT.md      # findings: version gap, config audit, surface
│   ├── TEST-RESULTS.md        # measured latency + end-to-end verification
│   └── README.md
├── tools/github_release.sh    # publish an ISO as a GitHub release asset
├── vendor/                    # vendored .deb(s) for AUR (makedeb)
├── output/                    # NOT tracked: published ISOs + latest.json
│   └── kernel/                # published kernel .deb packages
├── promptli-os/               # LEGACY (macOS-era i3 project files) — unused
├── promptli-os-source.zip     # LEGACY
├── CONTEXT_FOR_X64.md         # LEGACY handoff (outdated; this document replaces it)
└── Readme.md                  # LEGACY narrative (historical, not current docs)
```

**Important:** `promptli-os/` (lowercase-hyphen) is the old desktop/i3 project.
It is **not used** by the current build. Do not "fix" it, and do not
reintroduce i3/GUI assets from it. `Readme.md` and `CONTEXT_FOR_X64.md`
describe that old world; they are historical.

### 3.2 Website repo — `/home/ufi/Documents/v3.1/cont/v3.1`

Remote: `https://github.com/c4mandry/insight-inweave.git` (branch `main`).
It is **outside** `/home/ufi/promptlix`, so file-editing tools restricted to
the project root cannot touch it — use the terminal.

The OS-related files are:

```
src/routes/os.tsx            # /os landing + download page
src/routes/os-install.tsx    # /os/install instructions page
src/server/os-api.ts         # /api/os/* endpoints
src/server.ts                # wires os-api before the TanStack handler
```

It is a **TanStack Start** (React + Nitro) app. Production runs as a
**user-level systemd service** called `webnotes-prod`.

---

## 4. Versioning, releases and promotion

### 4.1 Versioning rule (set by the user — follow it exactly)

`MAJOR.MINOR.PATCH`, encoded in `build_promptli.sh` line 11 (`VERSION=`):

- **MAJOR** — set by the user by hand. Do not bump it yourself.
- **MINOR** — +1 for a new feature or a big/behavioural change.
- **PATCH** — +1 for **every** bug fix, however small.

A release may bundle several patches, but each bug fix still means the patch
number moves. The version is also what the OS reports: it is written into
`/etc/os-release` (`VERSION_ID`), `fastfetch`, the update comparisons, and
the website manifest. Never ship an ISO whose `VERSION` doesn't match the
manifest/website strings.

Recent history (for context): `1.23.x` keymap/login fixes, `1.24.1`
self-update, `1.25.0` zsh config, `1.26.x` aido REPL/TUI, `1.27.0` aido
control tools, `1.28.0` installer driver selection + GitHub releases,
`1.28.1`/`1.28.2` driver/updater fixes, **`1.29.0` performance kernel**.

### 4.2 What "promoting a release" means

The website reads its manifest from disk (`output/latest.json`) at request
time, so publishing does **not** require a website rebuild for the manifest —
but it does for the hardcoded install-page strings. The full promotion
sequence is in §14.3.

---

## 5. The build system (`build_promptli.sh`)

This single script builds the whole ISO using Debian's **live-build**. It is
long (~1400 lines) because it generates the entire promptLi layer inline as
heredocs. Read it top to bottom once; the section headers make it navigable.

### 5.1 Invocation

```sh
cd /home/ufi/promptlix/PromptLi_os
sudo -n env PROMPTLI_OUTPUT_DIR=/var/tmp/outputXXXX bash build_promptli.sh
```

- Runs as **root** (debootstrap/chroot need it). The host has passwordless
  sudo for user `ufi`; the sudo password is `234`.
- `PROMPTLI_OUTPUT_DIR` controls where the ISO + `latest.json` land.
- Optional: `PROMPTLI_KERNEL_DEB=/path/linux-image-*.deb` bundles the custom
  performance kernel instead of Debian's (see §12.6).
- **Build directory:** `/var/tmp/promptli-build-${VERSION}` (version-specific
  on purpose — see the pitfalls in §15).
- **Duration:** roughly 15–25 minutes on 8 cores, dominated by apt downloads
  and squashfs compression. The kernel build is a separate ~60–100 min job.
- **Requirements:** Debian/Ubuntu x86_64 host, ≥ 10 GB free disk (25 GB
  comfortable), network access, `live-build`/`debootstrap` (the script
  installs them via apt).

### 5.2 Stage by stage

1. **Cleanup.** Lazy-unmounts leftover chroot mounts (`dev/pts`, `proc`,
   `sys`, `dev`) from interrupted builds, then `rm -rf` the build dir and
   output dir.
2. **live-build config.** `lb config` for a Debian 13 amd64 hybrid ISO, no
   memtest.
3. **Bootloader.** Custom `isolinux.cfg`/`grub.cfg` with **timeout 0 and no
   menu** — the ISO boots straight into promptLi. (The user asked to remove
   the old "Debian GNU/Linux … live system / fail-safe / utilities" menu.)
4. **Package list** (`config/package-lists/promptli.list.chroot`). See §5.3.
5. **Project files** (`/opt/promptli`, `locakhost`).
6. **Includes tree** (`config/includes.chroot`): all files that become part of
   the live filesystem — scripts, config, branding.
7. **Fast/norm scripts** (`promptli-fast`, `promptli-norm`) — see §6.4.
8. **Rust installer + updater** copy from
   `promptli-installer/target/release/promptli-install` (or `$PROMPTLI_INSTALLER_BIN`).
   The same binary is installed twice: as `promptli-install` and as
   `promptli-update`; it dispatches on `argv[0]`.
9. **aido** copy from `aido/` to `/opt/aido`, wrapper `/usr/local/bin/aido`.
10. **Vendor** (makedeb `.deb`) → `/opt/promptli/vendor`.
11. **Optional custom kernel** → `/opt/promptli/vendor/promptli-kernel.deb`
    (installed by the chroot hook, §12.6).
12. **OS identity**: `/etc/os-release` (`NAME="promptLi OS"`,
    `VERSION_ID=$VERSION`, `ID=promptli`, `ID_LIKE=debian`,
    `PRETTY_NAME="promptLi OS $VERSION (L1-433)"`), `/usr/lib/os-release`
    symlink, `/etc/motd`, `/etc/issue`,
    `/etc/profile.d/promptli-version.sh` (exports `PROMPTLI_VERSION`),
    `/etc/profile.d/promptli-path.sh` (adds sbin dirs to PATH).
13. **Hardening sysctls** `/etc/sysctl.d/90-promptli.conf` (§12.7).
14. **fastfetch config** `/etc/fastfetch/config.jsonc` + skel copy.
15. **zsh config** `/etc/zsh/zshrc` + skel `.zshrc` (§5.4).
16. **Oh My Zsh / starship** installed system-wide (§5.4).
17. **`promptli-term`** (console UTF-8 + font helper), **`promptli-kb`**
    (post-login keymap switch), **autostart framework**
    (`/etc/promptli/autostart.d/*.sh`, user dir in `~/.config/promptli/`).
18. **First-boot service** `promptli-setup.service` → `/opt/promptli/setup.sh`
    (ensures user exists, syncs skel, retries `mist` install, disables itself).
19. **Chroot hook** (`config/hooks/normal/9999-promptli-customize.hook.chroot`),
    which does the real system surgery inside the chroot:
    - console keymap via `/etc/default/keyboard` + `console-setup` cache;
    - AUR tooling (makedeb vendored `.deb`, `mist`), makepkg arch fix;
    - fast-boot/low-RAM tweaks (mask `systemd-networkd-wait-online`,
      `NetworkManager-wait-online`, `ModemManager`, `man-db.timer`,
      `fstrim.timer`, `cron.service`, **`wpa_supplicant.service`**,
      `e2scrub*`, `systemd-tmpfiles-clean.timer`; journald size caps;
      `NAutoVTs=2`);
    - networking: purge `live-config` + the whole `dbus*` daemon family,
      install `dbus-broker` + `systemd-resolved`, **reinstall
      `bluez wireplumber pipewire pipewire-pulse alsa-utils`** (the dbus
      purge removes them — this was a shipped bug until 1.28.2), re-assert
      keymap/font packages, `systemd-networkd` + resolved symlinks,
      `/etc/resolv.conf` → stub;
    - no display managers (purge `lightdm gdm3 sddm xdm`);
    - **no autologin** (delete `live-config-getty-generator`);
    - serial console GRUB settings (`console=tty0 console=ttyS0,115200`,
      `GRUB_TERMINAL="console serial"`);
    - tty1 getty wrapper `promptli-getty` (plain `agetty`, 115200, `linux`);
    - create default user `promptli` (password `promptli`, shell zsh,
      groups sudo,netdev,video);
    - **optional custom kernel install + purge of all Debian kernels**;
    - permissions.
20. **`lb build`** produces the ISO; the script copies it and regenerates
    `latest.json` with recalculated sha256/size.

### 5.3 Package list (the important parts)

- Base: `linux-image-amd64` (unless a custom kernel is bundled),
  `live-boot`, `live-tools`, `systemd-sysv`, `systemd-resolved`,
  `systemd-timesyncd`, `sudo`, `adduser`.
- **No `live-config`** — the distro configures users/hostname itself and
  dropping live-config removes a dbus daemon.
- Shell/tools: zsh (+autosuggestions, syntax-highlighting), fastfetch, fzf,
  eza, bat, ripgrep, fd-find, zoxide, btop, tmux, curl, wget, git, vim,
  htop, unzip, p7zip-full, less, rsync, ca-certificates.
- Console: `kbd`, `console-setup` (font + keymap loading on the plain
  console).
- Networking: `wpasupplicant`, `iw`, `wireless-tools`, `iproute2`.
- **Driver groups** (all present in the base so the installer can keep or
  purge them offline): `bluez` (bluetooth), `pipewire pipewire-pulse
  wireplumber alsa-utils` (audio), wifi from the networking line.
- Firmware (non-free-firmware): `firmware-linux`, `firmware-misc-nonfree`,
  `firmware-iwlwifi`, `firmware-realtek`, `firmware-ath9k-htc`,
  `firmware-brcm80211`, `firmware-intel-sound`, `firmware-sof-signed`.
- Disk/provisioning: `parted fdisk util-linux dosfstools squashfs-tools gdisk
  cryptsetup`.
- Bootloader: `grub-pc-bin grub-efi-amd64 grub-efi-amd64-bin efibootmgr
  os-prober`.
- Arch-style tooling: `pacman-package-manager`, `gnupg`, `build-essential`,
  `binutils`, `fakeroot`, `file`, `gettext`, `gawk`, `libarchive-tools`,
  `lsb-release`, `zstd`.
- Python (aido/locakhost): `python3 python3-pip python3-venv python3-yaml
  python3-requests`.

### 5.4 zsh / fastfetch / console conventions

- **zsh** is the default shell (user and root). `/etc/zsh/zshrc` is copied to
  `/etc/skel/.zshrc`. It is the user's own config (from his
  `endervouros2026` repo) plus promptLi additions:
  - Oh My Zsh from `/usr/share/oh-my-zsh`, `agnoster` theme forced to
    black & white, `starship` for real terminals;
  - on `TERM=linux` it falls back to a clean ASCII prompt with no powerline
    glyphs (the console cannot render them) — this was a hard-won fix;
  - plugins: git, zsh-autosuggestions, zsh-syntax-highlighting;
  - `promptli-autostart` hook sources `/etc/promptli/autostart.d/*.sh` once
    per login shell — this is where `fastfetch` runs, plus the post-login
    keymap switch.
- **fastfetch** config: braille logo (the user's own art — **do not change
  it**), monochrome (`color: { "1": "default" }`, `brightColor: false`),
  separator ` ➜ `, modules: title, separator, os, host, kernel, uptime,
  packages, shell, cpu, memory, disk, localip, colors.
- **Console font:** `Uni2-Terminus16` — required for the braille logo. The
  older `Lat2-Terminus16` shows boxes ("squares") instead of the art. This
  is set in `/etc/vconsole.conf` and in the installer's tmpfiles shadow file.
- **Keymap/login design (critical, do not regress):**
  - The **login console always uses US** so the password prompt is
    predictable. A regional layout at the password prompt is a classic
    "password looks right but is wrong" trap.
  - The user's chosen keymap is recorded in `/etc/promptli/keymap` and
    applied **after login** by `promptli-kb` (invoked from
    `/etc/promptli/autostart.d/15-keymap.sh`).
  - `write_keymap()` in the installer replaces the `/etc/vconsole.conf`
    symlink with a real file, sets `KEYMAP=us` + `FONT=Uni2-Terminus16`,
    writes `/etc/default/keyboard` with US layout, regenerates the
    console-setup cache with `setupcon --force --save`, and shadows
    Debian's `tmpfiles.d/debian.conf` so the symlink does not come back.
- **No autologin, ever.** The live-config getty generator is deleted; getty
  always asks for credentials.

---

## 6. Runtime system model (what an installed system looks like)

### 6.1 Boot and login

1. GRUB (UEFI or BIOS depending on install) → kernel (Debian's, or
   `6.12.115-promptli` in 1.29.0) with `console=tty0 console=ttyS0,115200`.
2. systemd starts; `dbus-broker` is the system bus; `systemd-networkd` and
   `systemd-resolved` handle networking; DHCP on wired ethernet via
   `/etc/systemd/network/10-wired.network`.
3. Two gettys (`NAutoVTs=2`). tty1 uses `/usr/local/bin/promptli-getty`
   (plain agetty, 115200, TERM=linux). Serial getty is forced to TERM=linux.
4. User logs in with `promptli`/`promptli` (or whatever the installer set).
5. zsh starts, sources `/etc/zsh/zshrc`, runs `fastfetch`, applies the
   post-login keymap.

### 6.2 What is deliberately absent

No Xorg/Wayland, no display manager, no NetworkManager, no ModemManager
(masked), no `live-config`, no `wpa_supplicant` service unless the installer
selected wifi, no cron (masked), no apt-daily timers in fast mode.

### 6.3 Update layers

promptLi has **two** update layers:

1. **Debian packages** — `apt upgrade` / `pacman -Su` (the pacman wrapper).
2. **The promptLi release layer** — aido, scripts, configs, installer,
   version string. That layer is shipped inside the ISO and applied in place
   by `promptli-update --apply` (§8).

### 6.4 `promptli-fast` / `promptli-norm` (bloat mode switch)

- **`promptli-fast`** (root; `sudo -E`): purges zsh/fzf/eza/bat/ripgrep/fd/
  zoxide/btop/tmux/fonts/python3/man-db/manpages/unzip/p7zip/htop; removes
  `/opt/aido`, the promptli tools, Oh My Zsh, starship, `aido`,
  `promptli`, `locakhost`, `promptli-term`; switches user and root shells to
  **bash** with `usermod` (not `chsh` — see §15); masks optional units
  (apt-daily timers, man-db, tmpfiles-clean, e2scrub, fstrim, ModemManager —
  **but not wpa_supplicant**, so wifi keeps working); sets journald caps;
  sets `NAutoVTs=1`; writes the mode **inside the quotes** of
  `PRETTY_NAME`/`VERSION` in `/etc/os-release` (`… (L1-433) fast`), touches
  `/etc/promptli/fast`, removes `/etc/promptli/norm`.
  It **keeps** pacman/AUR (makedeb, mist), the installer/updater,
  networking, fastfetch, kernel, bootloader.
- **`promptli-norm`**: reinstalls packages from the internet, restores aido
  and the shell/tools from the live ISO squashfs if booted from it,
  otherwise downloads the current ISO from `/api/os/iso`; switches shells
  back to zsh; re-enables apt timers; re-applies the build's mask set (but
  unmasks `wpa_supplicant` if it is installed); restores the getty wrapper;
  writes ` norm` in os-release; removes `/etc/promptli/fast`, touches
  `/etc/promptli/norm`.
- Fresh installs are marked **norm** by the installer (marker file +
  os-release suffix), so fastfetch always shows the mode:
  `OS ➜ promptLi OS 1.29.0 (L1-433) norm x86_64`.

---

## 7. The Rust installer (`promptli-installer/`)

A single small Rust binary, built with `cargo build --release`. Dependencies:
`ratatui`, `crossterm`, `serde`, `serde_json`, `ureq` (rustls). No OpenSSL.

### 7.1 Dispatch

`main.rs` checks `argv[0]`: if it contains `promptli-update`, it runs the
updater; otherwise the installer. `promptli-install update …` also works.

The installer **refuses to run as non-root** with a friendly message
("promptli-install needs root… run with sudo"). This exists because
partitioning needs root and an unprivileged run produced confusing
`sfdisk: permission denied` errors.

### 7.2 Two modes

1. **Interactive TUI** (`promptli-install` with no `--disk`): archinstall-style
   menu. Screens (`Screen` enum): `Menu`, `Disk`, `Layout`, `Swap`,
   `Drivers`, `Hostname`, `Username`, `Password`, `RootPassword`, `Keymap`,
   `Timezone`, `Review`, `Done`.
   - Menu order (index matters for tests): 0 Disk, 1 Partitioning, 2 Swap,
     3 Drivers, 4 Hostname, 5 Username, 6 Password, 7 Root password,
     8 Keyboard, 9 Timezone, 10 Review & install, 11 Install now.
   - Number keys jump: `1`→0 … `9`→8, `0`→9.
   - Navigation: `j`/`k` or arrows, `Enter` opens/confirms, `h`/`Esc` back,
     `q` quits.
   - Drivers screen: toggle wifi/bluetooth/audio with `y`/`n`/`Enter`.
   - Review shows the full config summary (no passwords) and installs on
     `Enter`.
2. **Unattended CLI**: `promptli-install --disk vda [flags]`. See `--help`
   (hostname/user/password/root-password/keymap/timezone/site/swap/drivers/
   efi|bios).

Defaults: hostname `promptli`, user `promptli`, password `promptli`, root
password empty (**root locked**), keymap `us`, timezone `UTC`, site
`https://webnotes.work`, swap on, layout EFI, **drivers `wifi` only**.

### 7.3 The install pipeline (`install.rs::run_install`)

1. `partition_disk()` (`disk.rs`): `sgdisk --zap-all` + `wipefs --all`, then
   `sfdisk` with a script:
   - EFI: GPT, `,512M,U` (ESP), optional swap partition, root = rest.
   - BIOS: DOS label, optional swap first, root last with boot flag.
   Then `partprobe` + `udevadm settle` (twice) because VM kernels often fail
   to re-read the table, then `mkfs.fat -F32`, `mkfs.ext4 -L <hostname>`,
   `mkswap`.
2. Mount root (and `/boot/efi` on EFI).
3. **Extract the live filesystem**: `unsquashfs -f -no-progress -d <target>`
   from `/run/live/medium/live/filesystem.squashfs` (fallbacks listed in
   `common.rs::LIVE_SQUASHFS_PATHS`); if the live root is an already
   unpacked rootfs, `rsync -aAXx` instead. **The installer never downloads
   anything to install — it is fully offline.**
4. `write_hostname`, `write_fstab` (UUIDs), `write_keymap` (see §5.4),
   `write_timezone`, `enable_serial_console` (GRUB cmdline + serial +
   term settings), `create_user` (useradd + chpasswd; `passwd -l root` when
   no root password).
5. `apply_drivers()`: for each group **not** selected, `dpkg --purge
   --force-depends` the packages in the chroot; for selected groups, remove
   the base image's fast-boot mask symlink for the group's service
   (e.g. `wpa_supplicant.service`).
6. `mark_norm_mode()`: writes `/etc/promptli/norm` and appends ` norm` inside
   the quotes of `PRETTY_NAME`/`VERSION` in the target's os-release.
7. `install_bootloader()`: bind-mounts `/dev /proc /sys` into the target,
   then `grub-install` + `update-grub`:
   - EFI: `--target=x86_64-efi --efi-directory=/boot/efi
     --bootloader-id=promptLi --force-extra-removable` when EFI runtime is
     present, otherwise `--removable` (works with empty NVRAM).
   - BIOS: `--target=i386-pc --recheck <disk>`.
   - `physical_disk()` strips partition suffixes (`/dev/nvme0n1p2` →
     `/dev/nvme0n1`).
8. `install_updater_files()`: makes sure apt-daily timers are not masked.
9. **Enrollment**: POST `/api/os/install` with `{version, hostname,
   machine_id}`; the server returns `{token}`. Best-effort — failure only
   prints a warning.
10. Writes `/etc/promptli/install.json` (`version`, `site_url`, `token`,
    `machine_id`, `installed_at`) into the target — **used by the updater**.
11. `sync`, unmount, done. In the TUI the result is shown on the Done screen
    and Enter exits; the TUI never runs the install a second time.

### 7.4 Error philosophy

Every step that must succeed uses `run(...)?` and propagates an error; the
TUI prints `❌ ERROR: …` and stays on the Done screen. Optional steps
(enrollment, some chroot tweaks) are best-effort and never abort.

---

## 8. Self-update (`promptli-update`)

`update.rs` implements the two-layer update. `main.rs` loads
`/etc/promptli/install.json` and passes it in, so the updater uses the
**machine's own** site URL (a custom `--site` is honoured).

- `promptli-update --check`: `apt-get update`, counts upgradable packages,
  then fetches `/api/os/latest` and compares versions numerically
  (`compare_version`, e.g. 1.9.0 < 1.10.0). Reports if a newer promptLi
  release exists. Offline → silent.
- `promptli-update --apply` (also what `pacman -Syu` runs):
  1. `apt-get upgrade -y` (Debian layer).
  2. If a newer release exists: download the ISO from
     `<site>/api/os/iso`, mount it (`mount -o loop,ro`), and
     `unsquashfs -f -no-progress -d / <squashfs> <paths>` where `<paths>` is
     the promptLi-owned set: `opt/aido opt/promptli etc/fastfetch etc/skel
     etc/zsh etc/promptli/autostart.d etc/profile.d/promptli-version.sh
     etc/profile.d/promptli-path.sh usr/local/bin/{aido,pacman,promptli,
     promptli-term,promptli-kb,promptli-fast,promptli-norm,promptli-install,
     promptli-update,promptli-getty,locakhost,starship} usr/share/oh-my-zsh
     usr/share/aido`.
  3. `os-release` is handled **separately**: the new file is copied, and the
     old fast/norm suffix is re-inserted **inside the quotes** (the suffix
     must never be appended after the closing quote, and the regex must not
     expect parentheses — both were bugs).
  4. `chmod +x` the binaries, unmount, delete the temporary ISO.
- The **installed version is `VERSION_ID`** in `/etc/os-release`
  (`common.rs::distro_version`), so never put the mode suffix there.
- The update never touches the bootloader or partitions, and never
  reinstalls the kernel (kernel updates come through apt in 1.28.x; in
  1.29.0 the custom kernel is a normal installed package).

---

## 9. AUR support on Debian

Three pieces:

1. **`/usr/local/bin/pacman`** (shell wrapper; `/usr/local/bin` wins on PATH
   over `/usr/bin/pacman`):
   - `-S pkg`: if `apt-cache show pkg` succeeds → `apt-get install`; else
     clone `https://aur.archlinux.org/pkg.git` and build with `makedeb -si
     --no-confirm`. When run as root it drops back to `$SUDO_USER` for the
     build (makepkg/makedeb refuse to run as root).
   - `-Syu`/`-Suy` → `promptli-update --apply` (§8); `-Sy` → apt update;
     `-Su` → apt upgrade.
   - `-Ss` → `apt-cache search`, `-Si` → `apt-cache show`, `-Q` → dpkg
     listing, `-R` → apt remove, `-Sc` → apt clean, `--help`.
   - `pacman -V` prints the OS version.
2. **`makedeb`** — vendored `.deb` under `vendor/`, installed in the chroot
   hook (with `--force-overwrite` because Debian's makepkg also ships
   `/etc/makepkg.conf`). The build also fixes `makepkg.conf` architecture
   for AUR builds.
3. **`mist`** — from the makedeb repo; if the repo was down during the
   build, `promptli-setup.service` retries on first boot.

Known good: `pacman -S yay` works on promptLi (verified in QEMU).

---

## 10. aido — the AI assistant

### 10.1 Layout and entry points

- Source: `aido/` → installed to `/opt/aido` (src + config + requirements +
  setup.py). Roles to `/usr/share/aido/roles`.
- Wrapper `/usr/local/bin/aido` → `python3 /opt/aido/src/aido.py`.
- `/usr/local/bin/promptli` is a legacy alias that execs `aido`.
- Model: local GGUF via `aido setup` → `~/.aido/models/granite.gguf`
  (Granite 4.0 H 1B Q4_K_M), backend installed by the same command.
  The assistant is **offline-first**; a remote API key is optional.

### 10.2 Interfaces

- **REPL (default, `aido` with no args)** — aichat-style line interface with
  streaming markdown, syntax-highlighted code via `bat`, and dot-commands:
  `.help .info .model <path> .role [name|--create] .session [name]
  .file <path> .editor .sudo .auto .tools .exit/.quit`.
  Sessions are auto-saved as YAML under `~/.aido/sessions/`.
- **One-shot**: `aido "question"` or `aido -e "…"`.
- **TUI**: `aido tui` (curses) — `Shift+S` toggles sudo mode (asks for the
  sudo password once, keeps it in memory), `/help`, status bar.
- **Utilities**: `aido tools`, `aido doctor` (backend/model/network/key
  diagnostics), `aido key set|show|clear`, `aido setup`.
- Flags: `-s/--session`, `-r/--resume`, `--model`, `--config`, `--yes`,
  `--list-tools`, `--verbose`.

### 10.3 Tools (35) and safety model

Tools are declared in `tools.py::TOOL_REGISTRY` (name, description,
parameters, `dangerous`) and mapped 1:1 in `TOOL_FUNCTIONS` (an assert keeps
them in sync). They cover: file listing/search/info, window management
(list/move/resize/minimize/maximize/focus/close — legacy GUI tools, harmless
on a console), screen size/screenshot, launch app, process list/terminate,
system info, config read/edit/backup/restore, HTTP fetch/browse/download,
`run_command`, file CRUD (`read_file write_file append_file create_directory
delete_path move_path copy_path`), package install/remove, service actions,
network info.

Safety:

- **Path sandbox** (`resolve path`): operations are restricted to
  `~ /etc /opt /srv /var/log /var/www /tmp /usr/local` (plus the session
  dirs). Anything else raises `AidoError`.
- **Dangerous tools** require confirmation, unless:
  - `.auto` mode (no confirmations at all), or
  - sudo mode (the user supplied the root password, which is treated as
    blanket approval).
- Tool errors never kill the conversation (caught and reported).
- `max_tool_iterations` defaults to 10 (`aido.yaml`).

### 10.4 Encrypted API key

`aido key set|show|clear` stores a remote-provider key in
`/etc/aido/secrets.enc`, **root:root 0600**, encrypted with AES-256-CTR +
HMAC-SHA256 (encrypt-then-MAC) using a PBKDF2-SHA256 (200k iterations) key
derived from a user passphrase, via `openssl` (no extra dependencies). Only
root can set/show/clear; unprivileged reads fail on permissions.

---

## 11. Website & distribution API

### 11.1 Pages

- **`/os`** — public, text-first (almost no CSS), dark; shows the manifest
  (version, size, sha256, release notes, default credentials) and a prominent
  **Download** button pointing at `/api/os/iso`. No login required.
- **`/os/install`** — install instructions: checksum verification
  (`sha256sum promptli-os-<version>-amd64.iso`), `dd` to USB, booting in
  QEMU/VirtualBox/UTM. These strings are hardcoded per version — **bump them
  on every release**.

### 11.2 API (`src/server/os-api.ts`)

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/os/latest` | GET | Public JSON manifest (read from `output/latest.json`; `iso_filename` is stripped from the response) |
| `/api/os/latest?token=…` | GET | Same + records an `update_check` enrollment |
| `/api/os/iso` | GET/HEAD | Streams the ISO (public; correct filename in `content-disposition`) |
| `/api/os/download` | GET | 302 → `/api/os/iso` |
| `/api/os/install` | POST | Installer enrollment: `{version, hostname, machine_id}` → `{token}` |

Key implementation details:

- `OS_OUTPUT_DIR` env (default `/home/ufi/promptlix/PromptLi_os/output`);
  manifest read on every request → **publishing is just replacing the ISO +
  `latest.json`**.
- `isoPath()` derives the filename from `manifest.iso_filename`, falling back
  to ``promptli-os-${manifest.version}-amd64.iso``. (Hardcoding it once
  caused the site to serve a stale ISO — do not reintroduce a fixed filename.)
- Enrollments → console + `/var/lib/promptli/enrollments.jsonl`
  (`PROMPTLI_ENROLLMENTS_PATH`) + optional Supabase mirror
  (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`). Supabase is *only* for the
  registry; downloads never touch accounts. Earlier versions required a
  Supabase login for downloads — the user explicitly wanted **no login**.
- Uses `service_role` key server-side only.

### 11.3 Deployment

```sh
npm --prefix /home/ufi/Documents/v3.1/cont/v3.1 run build
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart webnotes-prod
```

The service is user-level; it must be restarted after a build. Verify with:

```sh
curl -sS https://webnotes.work/api/os/latest | python3 -m json.tool | head
curl -sSI https://webnotes.work/api/os/iso | grep -i content-disposition
```

---

## 12. The performance kernel (`kernel/`)

Added for **1.29.0**. This is a real kernel project, not a config tweak.

### 12.1 What was found (security audit)

`kernel/SECURITY-AUDIT.md` documents it in full. Summary:

- The 1.28.x ISO shipped **6.12.113**; the current 6.12 LTS was **6.12.115**.
  Delta: **1,102 commits, 399 security-relevant** (UAF ×108, races ×102,
  info leaks ×84, OOB ×54, overflow ×38, double-free ×11). Notable missing
  fixes: ksmbd heap OOB write/slab OOB read/tree-connection UAF, dm-integrity
  buffer overflow, dm-verity FEC overflow, libceph `__ceph_x_decrypt` OOB,
  sockmap UAF in `udp_bpf_recvmsg`, bpf sock-clone UAF, ipvs OOB, etc.
  Hot subsystems: wifi (23), net (17), Bluetooth (14), scsi (12), ocfs2 (11),
  ksmbd (8), bpf (8), btrfs (8), rose+ax25 (16).
- The Debian base config is already well hardened (KSPP set). Added
  `ZERO_CALL_USED_REGS`, `SCHED_CORE`, `BPF_JIT_ALWAYS_ON`.
- Runtime hardening shipped as `/etc/sysctl.d/90-promptli.conf` (§12.7).
- Remaining risks documented: `MODULE_SIG_FORCE` off, no Secure Boot signing,
  no Clang/ThinLTO/CFI yet.

### 12.2 How the kernel is built (`kernel/build_kernel.sh`)

```sh
cd PromptLi_os/kernel
./build_kernel.sh                 # 6.12.115, x86-64-v3
VERSION=6.12.116 MARCH=x86-64-v2 ./build_kernel.sh
SURFACE=0 ./build_kernel.sh       # keep ham-radio etc.
INSTALL=1 ./build_kernel.sh       # dpkg -i + update-grub
```

The script:

1. Downloads `linux-<ver>.tar.xz` from kernel.org and **verifies sha256**
   against `sha256sums.asc`.
2. Downloads the **BORE 7.0** patch pinned to commit
   `1e2f57ad74e8b8b1d315c03b7abd8d74e40448b4`
   (`patches/stable/0001-linux6.12.37-bore-7.0.0.patch`).
3. Applies it with **`patch -F0`** and aborts on any fuzz/reject. (The patch
   is written for 6.12.37; it applies to 6.12.115 with offsets only.)
4. Copies a base config (`BASE_CONFIG=auto` → `/boot/config-$(uname -r)`,
   i.e. Debian's) and applies the promptLi profile via `scripts/config`:
   - `SCHED_BORE=y`, `HZ=1000`, `PREEMPT=y` (+`PREEMPT_DYNAMIC`)
   - `ZSWAP_DEFAULT_ON=y`, zstd compressor
   - `TRANSPARENT_HUGEPAGE_MADVISE=y` (not `always`)
   - `TCP_CONG_BBR=y` + `DEFAULT_BBR=y`
   - `ZERO_CALL_USED_REGS=y`, `SCHED_CORE=y`, `BPF_JIT_ALWAYS_ON=y`
   - KSPP set asserted (`INIT_ON_ALLOC_DEFAULT_ON`, `SLAB_FREELIST_HARDENED`
     + `RANDOM`, `HARDENED_USERCOPY`, `FORTIFY_SOURCE`,
     `STACKPROTECTOR_STRONG`, `X86_KERNEL_IBT`, `RANDOMIZE_*`,
     `STRICT_KERNEL_RWX`, `STRICT_MODULE_RWX`, `BUG_ON_DATA_CORRUPTION`,
     `BPF_UNPRIV_DEFAULT_OFF`, `LEGACY_TIOCSTI=n`, `DEVKMEM=n`)
   - `LOCALVERSION="-promptli"`
   - optional `SURFACE=1` (default): disable `HAMRADIO AX25 ROSE NETROM MKISS
     6PACK BPQETHER ATALK NFC IEEE802154` (DCCP/RDS/TIPC/CAN stay as modules).
5. `make olddefconfig`, asserts the headline options survived, then builds
   `make -j$JOBS KCFLAGS="-march=$MARCH" bindeb-pkg`.
6. Emits `linux-image-<ver>-promptli_<ver>-N_amd64.deb`,
   `linux-headers-…`, `linux-libc-dev…`, `linux-image-…-dbg…` in `$WORKDIR`.

**Important:** the `.config` in `kernel/promptli-kernel.config` is the exact
config of the shipped 1.29.0 kernel — and that build was made **before**
`SURFACE=1` existed, so it still contains the ham-radio *modules*
(`HAMRADIO=y`, `AX25=m`, `ROSE=m`). This is documented in the audit. Rebuilding
with the current script trims them.

### 12.3 Measured results (`kernel/TEST-RESULTS.md`)

QEMU/KVM, `-cpu host -smp 2`, identical initramfs, 3 interleaved rounds:

| Metric | Debian 6.12.96 | promptLi 6.12.115 |
|---|---|---|
| Max wakeup latency under a CPU hog on the same core | 6.3–8.2 ms | **0.27–0.61 ms** (~22× better) |
| Avg wakeup latency | ~71.7 µs | **~55.5 µs** |
| getpid/write/fork/pipe syscalls | — | parity (no regression) |

Feature verification: `sched_bore=1`, `sched_burst_smoothness=1`, TCP `bbr`,
THP `[madvise]`, zswap `Y`, mitigations unchanged.

### 12.4 End-to-end

1.29.0 ISO built with `PROMPTLI_KERNEL_DEB` was booted live and installed in
QEMU: live `uname -r` = `6.12.115-promptli`, `/boot` contains exactly one
kernel, `promptli-install` completed, installed system booted the same kernel
with BORE active.

**Test-environment note:** under heavy *host* memory pressure (host swap
full, 3 GB guest), **both** this kernel and the stock Debian kernel printed
`rcu_preempt detected stalls` during unsquashfs; with a 2 GB guest and page
cache dropped, both complete cleanly. It is host overcommit, not a BORE bug.

### 12.5 ISO integration

`build_promptli.sh` accepts:

```sh
PROMPTLI_KERNEL_DEB=/home/ufi/promptlix/PromptLi_os/output/kernel/linux-image-6.12.115-promptli_6.12.115-2_amd64.deb \
  sudo -n env PROMPTLI_OUTPUT_DIR=/var/tmp/outputXXXX bash build_promptli.sh
```

The script copies the `.deb` into `config/includes.chroot/opt/promptli/vendor/
promptli-kernel.deb`; the chroot hook installs it, marks `initramfs-tools`
manual, purges **all** non-promptli `linux-image-*` packages, regenerates the
initramfs, and removes the bundled `.deb`. The result is an ISO with exactly
one kernel.

**GRUB path fix (learned the hard way in 1.29.0 → 1.29.1):** live-build
generates the GRUB kernel path as
`DEFAULT_KERNEL="$(basename chroot/boot/vmlinuz-*${DEFAULT_FLAVOUR})"` with
flavour `amd64`. A custom kernel whose release does not end in `-amd64`
(e.g. `6.12.115-promptli`) makes that glob stay **literal**, producing
`linux /live/vmlinuz-*amd64` in `/boot/grub/grub.cfg`. GRUB does not expand
globs → UEFI boot dies with "file not found" / "you need to boot the kernel
first" (BIOS/isolinux uses the generic `/live/vmlinuz` and is unaffected).
`build_promptli.sh` now ships a **binary hook**
(`config/hooks/normal/9998-promptli-bootcfg.binary`) that runs after the boot
configs are generated and rewrites them to the real file names found in the
ISO staging tree. If you ever change the kernel naming again, keep this hook
(or make the kernel release end in `-<flavour>`).

### 12.6 Caveats

- **x86-64-v3** requires Haswell / Zen 1+ (the user's machine is a Ryzen 7
  4700U, fine). Rebuild with `MARCH=x86-64` for older CPUs.
- **No Secure Boot signing**; users must enroll a MOK or disable Secure Boot.
- **`MODULE_SIG_FORCE` is off** so out-of-tree modules load.
- **No Clang/ThinLTO/CFI** (GCC toolchain). This is the next big
  performance/security step.
- Only GCC is installed on the host; `CONFIG_LTO_GCC` does not exist for
  x86 — do not try to "just enable LTO" with GCC.

### 12.7 Hardening sysctls shipped (`/etc/sysctl.d/90-promptli.conf`)

`kptr_restrict=2`, `dmesg_restrict=1`, `unprivileged_bpf_disabled=1`,
`yama.ptrace_scope=1`, `perf_event_paranoid=3`, `bpf_jit_harden=2`,
`fs.protected_{hardlinks,symlinks,fifos,regular}` hardened,
IPv4 rp_filter/redirects/source-routing off, `tcp_syncookies=1`,
`default_qdisc=fq`, `vm.swappiness=100`.

---

## 13. Testing infrastructure

Tests are **not** in the repo; they live in `/var/tmp/qemu-driver/` on the dev
host (machine-specific). They boot ISOs/disks over a **serial console** and
drive them with Python (`subprocess` + pipes). Learn these patterns:

### 13.1 Pattern

- Boot: `qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 2048 \
  -kernel <extracted vmlinuz> -initrd <extracted initrd> \
  -append "boot=live components quiet console=ttyS0,115200" \
  -cdrom <iso> -drive file=<qcow2>,format=qcow2,if=virtio \
  -display none -serial stdio -no-reboot -netdev user,id=n0 -device e1000,netdev=n0`
- A reader thread copies bytes to stdout and buffers the last ~2–3 KB to
  detect prompts (`login:`, `Password:`) and markers.
- Log in with `promptli` / `promptli`.
- Send commands with `\n` (works on serial); `\r` is Enter for TUI/raw modes.
- Extract kernel/initrd from an ISO with `7z e -y <iso> live/vmlinuz
  live/initrd.img -o<dir>`.

### 13.2 Pitfalls that cost hours (memorise these)

1. **Never match a completion marker that appears in the command you type.**
   The tty echoes your input, so `echo DONE` triggers the `DONE` detector
   instantly. Either match a regex that only the *output* can produce
   (`UPDEXIT:[0-9]` vs the echoed `UPDEXIT:$?`), or wait for the shell prompt
   to come back, or watch for strings the command does not contain
   (`Installation complete`).
2. **Never match the bare word `password`** in a loop that feeds the prompt —
   the echoed command contains `--password …` and you will inject keystrokes
   mid-paste. Match `Password:` / `password for` / `[sudo] password`.
3. **Host memory pressure stalls guests.** The host has ~14 GB and a full
   6 GB swap; a 3 GB guest under I/O can starve vCPUs and produce
   `rcu_preempt detected stalls` (also on Debian's kernel). Use `-m 2048`,
   drop caches (`echo 3 | sudo tee /proc/sys/vm/drop_caches`), and don't
   run two 3 GB VMs plus a build at once.
4. **Background jobs get killed by later tool/command timeouts.** Launch long
   jobs with `setsid nohup … &`, and poll in short (< 2 min) calls.
   Also: the shell here is **dash** — no brace expansion (`{a,b}`), and
   `nohup cmd1 && cmd2 &` associates `&` only with the last element of the
   chain.
5. **Killing a build mid-way leaves chroot mounts.** `pkill -f
   build_promptli.sh` does **not** kill `lb build`/`debootstrap` children —
   they keep writing and corrupt the build dir. Kill the children too, lazy
   unmount, then `rm -rf`. That is why the build dir is version-specific.
6. **`-j8` kernel builds on 14 GB with zed open can OOM.** Use `-j4`.
7. **`bindeb-pkg` needs `debhelper`** (otherwise: "build
   dependencies/conflicts unsatisfied").
8. **The test shell prompt is per-host**: e.g. `promptli@drvall:~$`, so wait
   for the hostname before typing.
9. QEMU serial input can **drop characters** if you flood it while the guest
   is busy; keep commands short (drop default flags) and don't type during
   boot output.

### 13.3 Test matrix that should pass before a release

| Test | What it proves |
|---|---|
| TUI install (keys: Enter, Enter, `2`, Enter, `b`, Enter, `4`, Enter×2, `h`, `j`×8, Enter) | interactive installer, Drivers screen, install now |
| CLI `--drivers none` + boot | purge path works, still boots |
| CLI `--drivers all` + boot | wifi/bt/audio packages present, `wpa_supplicant.service` **not** masked, norm marker present |
| `promptli-update --apply` from N-1 | version bumps, mode suffix survives, drivers survive |
| `promptli-fast` then `promptli-norm` | both directions, markers, shell switch, os-release suffix |
| Live boot + `uname -r` + `sched_bore`/`tcp_congestion_control` | the kernel actually ships and is active |
| Install + boot on the release ISO | the installed system runs the same kernel |
| **UEFI boot** (OVMF) and **BIOS boot** (isolinux) of the ISO | bootloader configs resolve the real kernel (see the 1.29.1 GRUB fix); capture a screenshot via QMP `screendump` and check for the login prompt |
| `aido` pytest (`cd aido && python3 -m pytest tests -q`) | **82 passed, 2 skipped** |
| `cargo test` in `promptli-installer` | version-ordering test |

---

## 14. Runbook

### 14.1 Build an ISO

```sh
cd /home/ufi/promptlix/PromptLi_os
# bump VERSION in build_promptli.sh if needed (see §4.1)
sudo -n env PROMPTLI_OUTPUT_DIR=/var/tmp/outputXXXX bash build_promptli.sh
# log: tail -f the file you redirected to; done when "built successfully"
```

Output: `/var/tmp/outputXXXX/promptli-os-<VERSION>-amd64.iso` + `latest.json`.

### 14.2 Build the kernel (if needed)

```sh
cd PromptLi_os/kernel
# host needs: build-essential bison flex libssl-dev libelf-dev dwarves
#             xz-utils dpkg-dev fakeroot debhelper busybox-static (for tests)
./build_kernel.sh            # ~60–100 min on 8 cores with -j4
```

### 14.3 Promote a release

```sh
# 1. copy ISO + manifest into the served directory
cp /var/tmp/outputXXXX/promptli-os-<V>.iso          /home/ufi/promptlix/PromptLi_os/output/
cp /var/tmp/outputXXXX/latest.json                  /home/ufi/promptlix/PromptLi_os/output/
# 2. edit output/latest.json: add headline release_notes (version-specific)
#    keep version / iso_filename / sha256 / size_bytes consistent (the build
#    wrote them; only release_notes normally needs editing)
# 3. update the hardcoded filenames in the website install page
sed -i 's/promptli-os-<OLD>-amd64.iso/promptli-os-<V>-amd64.iso/g' \
  /home/ufi/Documents/v3.1/cont/v3.1/src/routes/os-install.tsx
npm --prefix /home/ufi/Documents/v3.1/cont/v3.1 run build
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart webnotes-prod
# 4. verify
curl -sS https://webnotes.work/api/os/latest | python3 -m json.tool | head
curl -sSI https://webnotes.work/api/os/iso | grep -i content-disposition
sha256sum /home/ufi/promptlix/PromptLi_os/output/promptli-os-<V>-amd64.iso
# 5. GitHub release (ISO), then optionally attach kernel .debs
cd /home/ufi/promptlix/PromptLi_os
setsid nohup ./tools/github_release.sh <V> output/promptli-os-<V>-amd64.iso \
  > /var/tmp/release<V>.log 2>&1 &
```

`tools/github_release.sh`:

- Token from `$GITHUB_TOKEN` or `~/.git-credentials` (user `c4mandry`, a
  `ghp_…` token).
- Creates or reuses the tag `v<V>` release, uploads the ISO as
  `promptli-os-<V>-amd64.iso`.
- Retries the upload 5× (connection timeouts are common), replaces a stale
  `422` asset, and **fails loudly** if the upload never returns HTTP 201.
- Use `Authorization: token <t>` (not Bearer) for `uploads.github.com`.

### 14.4 Install on a running system (kernel)

```sh
sudo dpkg -i linux-image-6.12.115-promptli_6.12.115-2_amd64.deb \
             linux-headers-6.12.115-promptli_6.12.115-2_amd64.deb
sudo update-grub && sudo reboot
```

---

## 15. Known bugs, gotchas and regressions to avoid

These are all things that *were* bugs and are fixed — do not reintroduce them:

| Area | Trap | Correct behaviour |
|---|---|---|
| Console font | `Lat2-Terminus16` renders the braille logo as **boxes** | `Uni2-Terminus16` everywhere (`vconsole.conf`, installer tmpfiles fallback) |
| Keymap | regional layout at the login prompt → "correct password rejected" | login always US; chosen layout applied post-login |
| chsh | `chsh` fails with "Authentication failure" when the shell is gone from `/etc/shells` under PAM | use `usermod -s` |
| Autologin | live-config's getty generator auto-logs in | delete `/lib/systemd/system-generators/live-config-getty-generator` |
| dbus purge | purging dbus removes `bluez`, `wireplumber`, `pipewire-pulse` | reinstall them after the purge (dbus package comes back, dbus-broker still runs via the `dbus.service` symlink) |
| wpa | base image masks `wpa_supplicant.service` | installer removes the mask when wifi is selected; fast mode must not mask it |
| os-release mode suffix | appended **outside** the quotes; regex expected `(fast)` | insert inside quotes; match ` fast`/` norm` without parens; never touch `VERSION_ID` |
| Website ISO path | hardcoded `promptli-os-1.x.y-amd64.iso` fallback served a stale ISO | derive from `manifest.version` |
| Release script | `set -e` + `CODE=$(curl …)` died on first failure; printed ✅ on 408 | `|| echo 000` and check for HTTP 201 |
| API | downloads required login (Supabase) | downloads are public; Supabase is only the enrollment mirror |
| ISO build dir | shared `/var/tmp/promptli-build` let a killed build corrupt the next one | version-specific `promptli-build-<VERSION>` |
| Installer build | stale `promptli-install` at repo root | build uses `promptli-installer/target/release/promptli-install` |
| TUI menu index | "Install now" is index **11** (Drivers was inserted at 3); tests that hardcode 10 break | keep the order or update every test |
| `promptli-update` | ignored the machine's own `--site`; didn't update autostart/profile scripts | pass `install.json` state; include the new paths |
| Provider | `--drivers all` used to keep a *missing* bluez | base image must actually ship bluez/wireplumber/pipewire (fixed 1.28.2) |
| Custom kernel + UEFI | live-build builds the GRUB path from `vmlinuz-*${DEFAULT_FLAVOUR}` (`amd64`); a kernel release like `6.12.115-promptli` leaves the glob literal → UEFI boot fails with "file not found" / "you need to boot the kernel first" (BIOS is fine) | binary hook `9998-promptli-bootcfg.binary` rewrites `boot/grub/grub.cfg` to the real `/live/vmlinuz-<release>` (fixed 1.29.1) |

Also: `promptli-os/` and `Readme.md`/`CONTEXT_FOR_X64.md` are **legacy**;
`vendor/` holds the makedeb `.deb`; `output/` is untracked.

---

## 16. Environment specifics (this dev machine)

- User `ufi`, sudo password **`234`** (passwordless sudoers is configured;
  `echo '234' | sudo -S …` always works). Never ask the user for it.
- Host: Debian 13, kernel `6.12.96+deb13-amd64`, 8 threads, ~14 GB RAM
  (tight — swap is often full), ~110 GB disk.
- Projects: `/home/ufi/promptlix/PromptLi_os` (OS) and
  `/home/ufi/Documents/v3.1/cont/v3.1` (website, **outside** the project
  root).
- Git commit identity for the OS repo:
  `Robert Põldmaa <c4mandry@users.noreply.github.com>`.
- GitHub token: `~/.git-credentials` (`c4mandry`, `ghp_…`); used by
  `github_release.sh`.
- Website service: `webnotes-prod` (user unit).
- Test workspace: `/var/tmp/qemu-driver/` (scripts + logs),
  `/var/tmp/iso-bootNNNN/` (extracted kernels), `/var/tmp/kernel/`
  (kernel build + `.deb`s), `/var/tmp/outputNNNN/` (build outputs).
- `/tmp` is a **tmpfs mounted nodev** — never build there (chroot device
  nodes fail). Use `/var/tmp`.

---

## 17. Roadmap / sensible next steps

1. **Clang + ThinLTO + CFI kernel variant** — the biggest remaining
   performance/security win; CachyOS builds this way. Needs `clang lld llvm`
   and a `CC=clang` path in `build_kernel.sh`.
2. **Multiple CPU-level kernel variants** (x86-64 baseline / v2 / v3 / v4),
   published as separate assets, so older hardware isn't excluded.
3. **Enable the attack-surface trim in the shipped kernel** (`SURFACE=1` is
   already the script default; rebuild + re-test) and re-run the audit.
4. **Module signing with a distro key** (`MODULE_SIG_FORCE`) once
   out-of-tree module needs are understood; plus Secure Boot signing.
5. **Kernel cadence**: rebuild from each new 6.12.y (monthly-ish); re-run the
   §1 version audit per release.
6. Consider **sched-ext** (`CONFIG_SCHED_CLASS_EXT` + scx_bpfland/lavd) as an
   alternative to the BORE patch, which needs maintenance per kernel bump.
7. A **`promptli-kernel`** helper on the ISO to install/verify kernel updates
   from the website (`output/kernel/` already holds the `.deb`s).
8. If AUR support needs to be more robust: test `mist` availability at build
   time, pin makepkg/makedeb versions, and add an AUR smoke test to CI.

---

## 18. Glossary

- **live-build** — Debian's ISO-building framework; this project generates a
  config tree and runs `lb build`.
- **squashfs** — the compressed read-only live filesystem inside the ISO;
  the installer unpacks it onto the target disk.
- **BORE** — "Burst-Oriented Response Enhancer", a CFS scheduling patch that
  favours low-burst (interactive) tasks.
- **MGLRU** — Multi-Generational LRU, the modern page-reclaim algorithm.
- **zswap** — compressed swap cache in RAM (avoids disk I/O on low RAM).
- **BBR** — Google's TCP congestion control (default here).
- **KSPP** — Kernel Self Protection Project (hardening config baseline).
- **makedeb / mist** — build/install AUR PKGBUILDs on Debian.
- **aido** — the assistant; **promptli-install** — installer;
  **promptli-update** — updater (same binary, `argv[0]` dispatch).
- **fast/norm** — the two bloat modes (§6.4).

---

## 19. Quick command appendix

```sh
# build
cd /home/ufi/promptlix/PromptLi_os && \
  sudo -n env PROMPTLI_OUTPUT_DIR=/var/tmp/outputX bash build_promptli.sh

# kernel
cd /home/ufi/promptlix/PromptLi_os/kernel && ./build_kernel.sh

# installer tests (host)
cd /home/ufi/promptlix/PromptLi_os/promptli-installer && cargo test
cd /home/ufi/promptlix/PromptLi_os/aido && python3 -m pytest tests -q

# website
npm --prefix /home/ufi/Documents/v3.1/cont/v3.1 run build
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart webnotes-prod
curl -sS https://webnotes.work/api/os/latest | python3 -m json.tool | head -20

# release
cd /home/ufi/promptlix/PromptLi_os && \
  ./tools/github_release.sh <VERSION> output/promptli-os-<VERSION>-amd64.iso

# git
cd /home/ufi/promptlix/PromptLi_os && git add -A && \
  GIT_AUTHOR_NAME="Robert Põldmaa" GIT_AUTHOR_EMAIL="c4mandry@users.noreply.github.com" \
  GIT_COMMITTER_NAME="Robert Põldmaa" GIT_COMMITTER_EMAIL="c4mandry@users.noreply.github.com" \
  git commit -m "<version>: <summary>" && git push origin main
```

---

## 20. SSH access (remote administration)

promptLi is console-first and ships **no SSH server by default** (it is a
server distro, so this is deliberate attack-surface reduction). `openssh-client`
is not installed either — only a zsh helper that starts an `ssh-agent` on
demand. If you want to administer the machine from another computer, install
and enable it: it is a normal Debian package on top of `apt`/`pacman`.

### 20.1 Install and enable the server

Run on the promptLi machine (from the console, or via the installer's shell):

```sh
sudo apt install -y openssh-server        # Debian package (pacman -S openssh also works)
sudo systemctl enable --now ssh           # unit is ssh.service (alias sshd.service)
systemctl status ssh --no-pager | head -5
ss -tlnp | grep ':22'                     # must show sshd listening
```

`pacman -S openssh` achieves the same: the `pacman` wrapper sees
`openssh-server` in the Debian archive and calls `apt-get install`.

### 20.2 Find the address and connect

```sh
# on promptLi
ip -4 addr show | grep 'inet '          # or: hostname -I
# fastfetch already prints "Local IP (ens<X>)" on login
```

Networking is `systemd-networkd` + DHCP on wired ethernet, so the address is
usually a `192.168.x.x` / `10.x.x.x` lease.

From your workstation:

```sh
ssh promptli@<ip-address>
# first connection: type "yes" to accept the host key, then the account password
```

The account password is whatever the installer set (default `promptli`). The
console keymap does **not** affect SSH — the password is transmitted as
characters, not as keystrokes on a regional layout.

### 20.3 Key-based login (recommended)

```sh
# on your workstation
ssh-keygen -t ed25519 -C "you@workstation"      # press Enter to accept defaults
ssh-copy-id -i ~/.ssh/id_ed25519.pub promptli@<ip>
ssh -i ~/.ssh/id_ed25519 promptli@<ip>            # should not ask for a password
```

If `ssh-copy-id` is unavailable, append the public key on the server:

```sh
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo 'ssh-ed25519 AAAA... you@workstation' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

### 20.4 Optional hardening

```sh
sudo tee /etc/ssh/sshd_config.d/10-promptli.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
X11Forwarding no
EOF
sudo systemctl restart ssh
```

**Keep your current session open** while testing the new config — if the key
auth is misconfigured you would otherwise lock yourself out. Root login is
already impossible by default (root is locked; `promptli` has sudo), so
`PermitRootLogin no` is belt-and-braces.

There is **no firewall enabled by default** on promptLi. If you add one
(nftables/ufw), remember to allow TCP 22 before restarting the SSH service.

### 20.5 Using SSH from promptLi (client side)

`openssh-client` is not installed by default either. It is needed for
`git@github.com:…` remotes, `scp`, `rsync` over SSH, and `ssh`. Install it:

```sh
sudo apt install -y openssh-client
```

### 20.6 SSH into a promptLi VM (QEMU test rig)

Forward port 22 to a host port in the QEMU command line:

```sh
qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 2048 \
  -drive file=/var/tmp/promptli-test-disk.qcow2,format=qcow2,if=virtio \
  -display none -serial stdio \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -device e1000,netdev=n0
# in the guest: sudo apt install -y openssh-server && sudo systemctl enable --now ssh
# from the host:
ssh -p 2222 promptli@127.0.0.1
```

(The existing test scripts in `/var/tmp/qemu-driver/` use
`-netdev user,id=n0` **without** `hostfwd`; add it when you need SSH.)

### 20.7 Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Connection refused` | sshd is not installed or not running: `systemctl status ssh`, `ss -tlnp \| grep :22` |
| `Connection timed out` / `No route to host` | wrong IP, different subnet, or the guest's DHCP lease changed: `ip a` on the server, `ping` from the client |
| `Permission denied (publickey)` | wrong username, or permissions: `~/.ssh` 700, `authorized_keys` 600, owned by the user |
| `Permission denied (password)` | wrong password — check the account, not the console keymap |
| Key rejected after reinstall | the host key changed: `ssh-keygen -R <ip>` on the client |
| `Host key verification failed` | same as above; or you are on the wrong host |
| Works locally, not from outside | NAT/firewall on the route; a VM needs `hostfwd` (see 20.6) |

Useful one-liners:

```sh
sudo journalctl -u ssh -n 50 --no-pager     # why sshd refused
sudo sshd -t                                # validate sshd_config syntax
sudo journalctl -u ssh -f                   # follow auth events (Debian 13 uses journald)
sudo systemctl restart ssh                  # apply config changes
sudo systemctl disable --now ssh            # turn SSH off again
```

---

## 21. Final notes for the next AI

- **Do not "improve" the ASCII logo, the version numbers, or the branding**
  unless asked. The user is specific about those.
- **Always test in QEMU** before claiming something works; run the full
  matrix in §13.3 when touching the installer, boot, keymap, drivers or the
  update path.
- **Explain tradeoffs** (e.g. full preemption vs throughput, hardening vs
  performance) instead of silently picking one.
- **Keep the two repos in sync**: a release that changes the ISO must update
  `output/latest.json`, the website install-page strings, and both git
  remotes.
- When something behaves oddly in a VM (stalls, timeouts, package failures),
  **check the host first** — memory pressure and background processes cause
  most of the "kernel bugs" seen in this project (proven by the control test
  in §12.4).
- The `SECURITY-AUDIT.md` and `TEST-RESULTS.md` files are the source of truth
  for the kernel claims; update them when you rebuild.

*End of handoff.*
