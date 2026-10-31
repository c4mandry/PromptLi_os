# promptLi OS kernel

A CachyOS-style performance kernel for promptLi OS: **BORE scheduler**, full
preemption, 1000 Hz, `-march=x86-64-v3`, MGLRU, zswap (zstd), TCP **BBR**,
and a hardening profile. Based on the **latest 6.12 LTS** (6.12.115 at the
time of writing), i.e. with all stable security fixes applied.

See [`SECURITY-AUDIT.md`](SECURITY-AUDIT.md) for the audit that motivates the
build (1,102 upstream commits and 399 security-relevant fixes are missing from
the 6.12.113 kernel shipped in promptLi 1.28.x).

## Quick start

```sh
# on a promptLi/Debian 13 machine with build tools:
sudo apt install build-essential bison flex libssl-dev libelf-dev \
                 dwarves xz-utils dpkg-dev fakeroot debhelper

cd PromptLi_os/kernel
./build_kernel.sh                 # builds 6.12.115 → .deb packages
# or a different version / CPU level:
VERSION=6.12.115 MARCH=x86-64-v2 ./build_kernel.sh
```

Packages land in `$WORKDIR` (default `/var/tmp/promptli-kernel`):

```
linux-image-6.12.115-promptli_...deb
linux-headers-6.12.115-promptli_...deb
linux-libc-dev-...deb
```

Install and boot:

```sh
sudo dpkg -i /var/tmp/promptli-kernel/linux-image-6.12.115-promptli_*.deb \
             /var/tmp/promptli-kernel/linux-headers-6.12.115-promptli_*.deb
sudo update-grub
sudo reboot
```

`INSTALL=1 ./build_kernel.sh` does the install step for you.

## What it changes

| Area | Setting |
|---|---|
| Scheduler | BORE 7.0 (`CONFIG_SCHED_BORE=y`), EEVDF base |
| Preemption | `PREEMPT=y` (full), `PREEMPT_DYNAMIC` for boot overrides |
| Tick | `HZ=1000` |
| Compiler | GCC, `-march=x86-64-v3` (override with `MARCH=`) |
| Memory | MGLRU on, zswap on with zstd, THP=madvise |
| Network | BBR default, CAKE/FQ available |
| Hardening | KSPP set + `ZERO_CALL_USED_REGS`, `SCHED_CORE`, `BPF_JIT_ALWAYS_ON` |
| Surface | ham radio (`ax25`/`rose`/`netrom`/`misss`/`6pack`), `atalk`, `nfc`, `ieee802154` disabled (`SURFACE=0` to keep) |

Runtime tuning (no reboot needed):

```sh
sudo sysctl kernel.sched_bore=1            # master switch
sudo sysctl kernel.sched_burst_smoothness=3
```

## Requirements / caveats

- **x86-64-v3** needs Haswell / Zen 1 or newer. For older CPUs build with
  `MARCH=x86-64` (or `x86-64-v2` for ~2009+).
- The kernel is **not signed for UEFI Secure Boot** and **module signature
  enforcement is off** (`MODULE_SIG_FORCE` unset) so out-of-tree modules work.
- No Clang/ThinLTO/CFI yet — see the audit's follow-ups (§5).

## Using it in the ISO

Drop the built `linux-image-*.deb` into the build and let the ISO ship it:

```sh
PROMPTLI_KERNEL_DEB=/var/tmp/promptli-kernel/linux-image-6.12.115-promptli_amd64.deb \
  sudo -E bash ../build_promptli.sh
```

(Integration point: the chroot hook installs the .deb and live-build picks up
`/boot/vmlinuz-6.12.115-promptli` for the ISO. This path is opt-in so the
default ISO stays on Debian's signed kernel until the custom one is validated.)

## Rebuilding for a new stable release

```sh
VERSION=6.12.116 ./build_kernel.sh
```

The script fetches the tarball, verifies the kernel.org sha256, applies the
pinned BORE patch with **zero fuzz** (fails loudly otherwise), applies the
profile, and builds `.deb`s. Re-run `SECURITY-AUDIT.md` §1 per release.
