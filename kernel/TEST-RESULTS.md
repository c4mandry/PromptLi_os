# promptLi performance kernel — test results

Tested 2026-10-31. Host: AMD Ryzen 7 4700U (8 threads), QEMU/KVM, guest with
`-m 1024 -cpu host -smp 2`, identical initramfs (busybox + a static benchmark
binary) and identical kernel command line for both kernels. The only variable
is the kernel image.

| Kernel | Version | Scheduler |
|---|---|---|
| Baseline | `6.12.96+deb13-amd64` (Debian 13, as shipped in promptLi 1.28.x) | EEVDF, HZ=250, voluntary preempt |
| promptLi | `6.12.115-promptli` | EEVDF + **BORE 7.0**, HZ=1000, full preempt |

## 1. Feature verification (booted, read from /proc, /sys)

| Check | Baseline | promptLi kernel |
|---|---|---|
| `uname -r` | `6.12.96+deb13-amd64` | **`6.12.115-promptli`** |
| `/proc/sys/kernel/sched_bore` | *missing* | **1** (BORE active) |
| `/proc/sys/kernel/sched_burst_smoothness` | *missing* | **1** |
| `net.ipv4.tcp_congestion_control` | `cubic` | **`bbr`** |
| `/sys/kernel/mm/transparent_hugepage/enabled` | `[always]` | **`[madvise]`** |
| `/sys/module/zswap/parameters/enabled` | `N` | **`Y`** |
| CPU mitigations (KVM guest) | retbleed, spectre_v1/v2, spec_store_bypass | **identical** (none dropped) |
| Boot | ✅ | ✅ (clean, `reboot: Power down` after init) |

## 2. Syscall / process microbenchmarks

Static benchmark, single run of each phase, 3 interleaved rounds.
Numbers are ns/op (lower is better); the variation between rounds is larger
than the difference between kernels.

| Benchmark | Debian 6.12.96 | promptLi 6.12.115 |
|---|---|---|
| `getpid()` | 89.8 / 84.1 / 86.3 | 84.5 / 86.9 / 86.8 |
| `write(/dev/null, 8B)` | 128.0 / 124.1 / 124.6 | 130.5 / 120.9 / 121.7 |
| `fork()+wait()` | 49.1 / 49.5 / 49.7 µs | 52.5 / 46.9 / 51.2 µs |
| `pipe write+read` | 413 / 431 / 430 | 459 / 415 / 431 |

**Conclusion:** syscall-path cost is at parity. The security options
(`ZERO_CALL_USED_REGS`, hardening set) do not measurably slow down syscalls
here; `-march=x86-64-v3` shows no regression either.

## 3. Responsiveness: SCHED_OTHER wakeup latency under CPU contention

Method: two busy loops pinned to CPU 0 (`taskset -c 0 yes`), then a normal
(SCHED_OTHER) process pinned to CPU 0 sleeps 1 ms and measures the overshoot,
4000 times. This is exactly the "does the shell/ssh/editor stay snappy while
something else hogs a core" scenario that full preemption + HZ=1000 + BORE
target.

| Round | Debian max | promptLi max | Debian avg | promptLi avg |
|---|---|---|---|---|
| 1 | 8184 µs | **608 µs** | 72.2 µs | **55.5 µs** |
| 2 | 6315 µs | **268 µs** | 72.1 µs | **55.6 µs** |
| 3 | 6680 µs | **75 µs** | 70.9 µs | **55.4 µs** |

**Worst-case wakeup latency: ~7.1 ms → ~0.32 ms (≈22× better).**
**Average wakeup latency: ~71.7 µs → ~55.5 µs (≈23% better.)**

The baseline's worst case is bounded by the 250 Hz tick + voluntary
preemption (the hog is not preempted until the next tick); the promptLi
kernel preempts it almost immediately and BORE keeps the interactive task's
burst short.

> These are VM numbers with `-cpu host`; on bare metal the absolute values
> shift, but the mechanism (tick granularity and preemption) is the same.

## 4. Security verification

- Booted from the **6.12.115** tree: the entire 6.12.113→6.12.115 delta
  (1,102 commits, 399 security-relevant) is included — see
  `SECURITY-AUDIT.md` §1.
- Hardening options present in the built package's
  `/boot/config-6.12.115-promptli` (extracted and checked):
  `SCHED_BORE=y`, `PREEMPT=y`, `HZ=1000`, `INIT_ON_ALLOC_DEFAULT_ON=y`,
  `ZERO_CALL_USED_REGS=y`, `X86_KERNEL_IBT=y`, `ZSWAP_DEFAULT_ON=y`,
  `TRANSPARENT_HUGEPAGE_MADVISE=y`, `DEFAULT_BBR=y`,
  `LOCALVERSION="-promptli"`.
- CPU vulnerability mitigations all still reported as mitigated/not-affected
  (identical to the Debian kernel in the same VM).

## 4b. End-to-end: live ISO and installed system

ISO `promptli-os-1.29.0-amd64.iso` was built with the new kernel, then
booted and installed in QEMU:

| Check | Result |
|---|---|
| Live ISO boots | ✅ |
| Live `/boot` contents | only `vmlinuz-6.12.115-promptli` (+ config, System.map, initrd) |
| Live `uname -r` | ✅ `6.12.115-promptli` |
| Live `sched_bore` / TCP / zswap | ✅ `1` / `bbr` / `Y` |
| `promptli-install` (CLI, BIOS, 8 GB disk) | ✅ `Installation complete` — all steps incl. driver selection, bootloader, enrollment |
| Installed system boots | ✅ |
| Installed `uname -r` / `sched_bore` / TCP | ✅ `6.12.115-promptli` / `1` / `bbr` |
| Installed `/boot/vmlinuz-*` | ✅ single kernel |

**Test-environment note:** under heavy *host* memory pressure (host swap full,
3 GB guest) both this kernel **and** the stock Debian kernel printed
`rcu_preempt detected stalls` during the unsquashfs step; with a 2 GB guest
and page cache dropped, the install completed cleanly on both. It is a
host-overcommit artefact, not a scheduling regression in the BORE kernel
(the control run on Debian's kernel stalls identically).

## 5. Artifacts

Built in `/var/tmp/kernel/` (kernel `6.12.115-promptli`, package version
`6.12.115-2`):

```
linux-image-6.12.115-promptli_6.12.115-2_amd64.deb   (110 MB)
linux-headers-6.12.115-promptli_6.12.115-2_amd64.deb  (9.9 MB)
linux-libc-dev_6.12.115-2_amd64.deb                   (1.4 MB)
linux-image-6.12.115-promptli-dbg_...deb              (1.0 GB, debug symbols)
```

Install on a running promptLi system:

```sh
sudo dpkg -i linux-image-6.12.115-promptli_6.12.115-2_amd64.deb \
             linux-headers-6.12.115-promptli_6.12.115-2_amd64.deb
sudo update-grub && sudo reboot
```
