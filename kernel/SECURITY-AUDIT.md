# promptLi OS — Kernel security audit & performance profile

Date: 2026-10-31 · Scope: the kernel shipped in promptLi OS 1.28.x
(`6.12.113+deb13-amd64`, Debian 13 base) and the replacement promptLi
performance kernel built from **6.12.115** (latest 6.12 LTS) with **BORE**.

This document is the result of downloading the kernel source, diffing the
stable releases, auditing the build configuration and rebuilding with
hardening + performance settings. Every claim below is reproducible with the
commands in `build_kernel.sh`.

---

## 1. The biggest security problem: the shipped kernel is behind stable

promptLi OS 1.28.x ships `6.12.113`. The current 6.12 LTS is `6.12.115`
(released 2026-10-30). The delta between the two is **not** cosmetic:

| Metric | Value |
|---|---|
| Upstream commits between 6.12.113 and 6.12.115 | **1,102** |
| Commits touching security-relevant code paths\* | **399** |
| …memory-safety: use-after-free | 108 |
| …race conditions | 102 |
| …information leaks / uninitialised memory | 84 |
| …out-of-bounds access | 54 |
| …overflow / underflow | 38 |
| …double-free | 11 |

\* keyword classification over commit subjects + messages (`use-after-free`,
`UAF`, `out-of-bounds`, `overflow`, `double-free`, `info leak`, `race`,
`null deref`, `type confusion`, `deadlock`). It is a lower bound on the
security-relevant changes, not a CVE count — Linux commits rarely carry CVE
IDs.

Top subsystems receiving security fixes in this window:

| Subsystem | Fixes | Notes |
|---|---|---|
| `wifi` | 23 | mac80211/cfg80211; reachable from any nearby radio |
| `net` | 17 | core networking |
| `Bluetooth` | 14 | reachable from any nearby radio |
| `scsi` | 12 | via any attached/emulated device |
| `ocfs2` | 11 | filesystem parsing (crafted image) |
| `net/mlx5` | 9 | |
| `ksmbd` | 8 | **SMB server** — remote, unauthenticated surface |
| `bpf` | 8 | |
| `btrfs` | 8 | filesystem parsing |
| `rose` + `ax25` | 16 | ham-radio protocols (see §3) |

Representative fixes missing from 6.12.113 (from the 6.12.114/115 changelogs):

- `ksmbd: fix heap out-of-bounds write in krb5_authenticate()`
- `ksmbd: fix slab-out-of-bounds read in ksmbd_alloc_user()`
- `ksmbd: fix tree connection use-after-free in smb2_tree_connect()`
- `ksmbd: defer publishing granted locks to prevent UAF/double-free race`
- `dm-integrity: fix buffer overflow with keyed discard`
- `dm-verity: fix buffer overflow in FEC calculation`
- `libceph: Fix potential out-of-bounds access in __ceph_x_decrypt()`
- `sockmap: Fix use-after-free in udp_bpf_recvmsg()`
- `bpf: Fix UAF in sock clone early bailouts`
- `netfilter` / `net/sched: cls_u32: validate offshift to prevent shift-out-of-bounds`
- `ipvs: revalidate ihl to prevent out-of-bounds access`
- `HID: core: Mitigate potential OOB by removing bogus memset()`
- `tap: fix stack info leak in tap_ioctl() SIOCGIFHWADDR`
- `xsk: drain continuation descs after overflow in xsk_build_skb()`
- `ALSA: seq: oss: Fix UAF at handling events with embedded SysEx data`

**Fix:** the promptLi kernel is built from **6.12.115**, i.e. the whole 1,102-
commit delta (including all of the above) is applied.

> **Status:** promptLi OS **1.29.0** (built 2026-10-31) ships this kernel;
the 1.28.x line still ships Debian's 6.12.113.

> Note: Debian's security team does backport fixes into `6.12.113+deb13`, so
> this gap is temporary in distro terms — but the promptLi kernel now tracks
> upstream stable directly, which is the CachyOS model.

---

## 2. Configuration audit (the base Debian config is already well hardened)

Checked against the kernel self-protection recommendations (KSPP):

| Option | Shipped 6.12.113 | Verdict |
|---|---|---|
| `INIT_ON_ALLOC_DEFAULT_ON` | `y` | ✅ zeroes heap allocations |
| `SLAB_FREELIST_HARDENED` / `_RANDOM` | `y` | ✅ |
| `STACKPROTECTOR_STRONG` | `y` | ✅ |
| `FORTIFY_SOURCE` | `y` | ✅ |
| `HARDENED_USERCOPY` | `y` | ✅ |
| `STRICT_KERNEL_RWX` / `_MODULE_RWX` | `y` | ✅ |
| `BUG_ON_DATA_CORRUPTION` | `y` | ✅ |
| `RANDOMIZE_BASE` / `_MEMORY` / `_KSTACK_OFFSET_DEFAULT` | `y` | ✅ KASLR + kstack offset |
| `X86_KERNEL_IBT` (CET) | `y` | ✅ ROP mitigation |
| `BPF_UNPRIV_DEFAULT_OFF` | `y` | ✅ |
| `LEGACY_TIOCSTI` | off | ✅ |
| `DEVKMEM` | off | ✅ |
| `INIT_STACK_ALL_ZERO` | `y` | ✅ (small perf cost) |
| `SECURITY_YAMA` / `APPARMOR` / `SELINUX` / `LOCKDOWN` | `y` | ✅ |
| `MODULE_SIG_FORCE` | **unset** | ⚠️ unsigned modules load (taint only) |
| `KALLSYMS_ALL` | `y` | ⚠️ symbol table readable by root (tools need it) |
| `USER_NS` | `y` | ⚠️ needed for containers; keep but restrict via sysctl |
| `IO_URING` | `y` | ⚠️ large historical CVE surface; module-only apps |
| `DEBUG_INFO` + BTF | `y` | ⚠️ build-time only; enables bpftrace/BCC |

**Added by the promptLi profile** (were missing or off):

| Option | New | Why |
|---|---|---|
| `ZERO_CALL_USED_REGS` | `y` | clears argument registers on return (GCC 12+) — limits register-reuse info leaks / ROP |
| `SCHED_CORE` | `y` | core scheduling — lets SMT siblings be isolated (side-channel containment) |
| `BPF_JIT_ALWAYS_ON` | `y` | removes the BPF interpreter (smaller attack surface, faster) |
| `INIT_ON_ALLOC_DEFAULT_ON` | kept `y` | (explicitly asserted) |
| `MODULE_SIG` | `y`, force off | modules signed at build time; enforcing requires a distro key — see §5 |

Deliberately **not** changed, with reasons:

- `KALLSYMS_ALL` — needed by `perf`, `drgn`, kdump workflows.
- `USER_NS` — containers require it; mitigate with `kernel.unprivileged_userns_clone=0` where containers are not used (documented in `README.md`).
- `IO_URING` — used by modern databases/runtimes; see §5 for an optional hardened variant.

---

## 3. Attack-surface reduction (real, measurable)

Debian ships the ham-radio stack and other dead protocol families that are a
recurring source of remotely-triggerable bugs — **16 of the 399 security
fixes above are `rose`/`ax25` alone**. A server distro does not need them.

Disabled by the build script's default profile (`SURFACE=1`):

```
HAMRADIO AX25 ROSE NETROM MKISS 6PACK BPQETHER ATALK NFC IEEE802154
```

This deletes the exact code paths that received those fixes, and trims the
module set. `DCCP`, `RDS`, `TIPC`, `CAN` are intentionally **kept as modules**
(edge/SBC and cluster use cases; they are not auto-loaded by unprivileged
users because creating those sockets requires `CAP_NET_ADMIN`).

> **Note on the attached test build:** the `linux-image-6.12.115-promptli`
> package verified in `TEST-RESULTS.md` was built before `SURFACE=1` was
> added to the script, so it still carries those protocol *modules* (built-in
> `HAMRADIO` core, `ax25`/`rose`/`netrom` as `.ko`). They are not loaded by
> default and cannot be instantiated without `CAP_NET_ADMIN`, so the exposure
> is limited. Rebuilding with the current script (`SURFACE=1`, the default)
> removes them entirely.

## 3b. Runtime hardening (shipped as a sysctl drop-in)

The distro now ships `/etc/sysctl.d/90-promptli.conf` (applied on live and
installed systems):

| Sysctl | Value | Effect |
|---|---|---|
| `kernel.kptr_restrict` | 2 | hides kernel pointers from all users |
| `kernel.dmesg_restrict` | 1 | dmesg only for root (info-leak reduction) |
| `kernel.unprivileged_bpf_disabled` | 1 | no unprivileged eBPF (KSPP) |
| `kernel.yama.ptrace_scope` | 1 | ptrace restricted to descendants |
| `kernel.perf_event_paranoid` | 3 | no unprivileged perf events |
| `net.core.bpf_jit_harden` | 2 | JIT constant blinding against spraying |
| `fs.protected_{hardlinks,symlinks,fifos,regular}` | hardened | blocks classic /tmp & symlink attacks |
| `net.ipv4.conf.*.rp_filter` | 1 | reverse-path filtering (anti-spoofing) |
| `net.ipv4.conf.*.accept_{source_route,redirects}`, `send_redirects` | 0 | no ICMP redirect/source-route tricks |
| `net.ipv4.tcp_syncookies` | 1 | SYN-flood resilience |
| `net.core.default_qdisc` | fq | required for BBR pacing |
| `vm.swappiness` | 100 | use compressed zswap before dropping cache |

---

## 4. Performance / responsiveness (CachyOS-style)

| Change | Shipped 6.12.113 | promptLi kernel | Effect |
|---|---|---|---|
| Scheduler | EEVDF | **EEVDF + BORE 7.0** | interactive tasks (shell, editor, ssh, compositor) get priority under CPU load |
| Preemption | voluntary | **full (`PREEMPT=y`)** | lower worst-case latency at a small throughput cost |
| Tick rate | 250 Hz | **1000 Hz** | finer scheduling granularity (BORE's base slice = tick) |
| Codegen | generic x86-64 | **`-march=x86-64-v3`** | BMI2/POPCNT/AVX2 paths; CachyOS uses the same level |
| Memory reclaim | MGLRU (enabled) | MGLRU (enabled) | kept — much better behaviour under pressure |
| Swap cache | zswap, LZO, off | **zswap on, zstd** | less blocking on low-RAM machines |
| THP | `always` | **`madvise`** | avoids khugepaged latency spikes on servers |
| TCP default | cubic | **BBR** | better throughput/latency on lossy or long-fat links |
| Sched debug | `SCHEDSTATS=y` | **off** | removes per-task accounting overhead |
| BTF/BPF | on | **JIT always on** | faster eBPF, no interpreter |

`MARCH` is a knob: use `MARCH=x86-64` for pre-2013 CPUs, `x86-64-v2` for
roughly 2009+, `x86-64-v3` (default) for Haswell/Zen1 and newer, and
`x86-64-v4` for AVX-512 machines. CachyOS ships the same idea as separate
v1/v2/v3/v4 builds.

### What this does *not* do (honest limits)

- **No LTO / CFI**: a GCC build cannot use `CONFIG_LTO_CLANG_THIN` or
  `CONFIG_CFI_CLANG`. CachyOS kernels are Clang+ThinLTO. Building a
  Clang/ThinLTO variant is the next step (needs `clang lld llvm`); the
  script is structured so `CC=clang` can be added.
- `-O3`: the kernel's Kconfig only exposes O2/Os on x86. Passing `-O3` to the
  whole kernel is not supported upstream and can miscompile; not enabled.
- Scheduler choice is compile-time (`BORE`). Boot-time override:
  `preempt=full|voluntary|none` on the kernel command line still works
  (`PREEMPT_DYNAMIC=y`).

---

## 5. Remaining risks & follow-ups

1. **Module signature enforcement** is off (`MODULE_SIG_FORCE` unset) so
   out-of-tree modules (e.g. NVIDIA, VirtualBox) keep working. Enabling it
   requires signing every module with a distro key and shipping that key in
   the kernel keyring. Tracked as a future hardening step.
2. **Secure Boot**: this kernel is not signed for UEFI Secure Boot. Users with
   Secure Boot must enroll a MOK or disable it (same as any custom kernel).
3. **Clang/ThinLTO + CFI** variant — biggest remaining performance/security
   win (CFI removes a whole class of control-flow hijack primitives).
4. **Update cadence**: rebuild the kernel from each new 6.12.y release
   (monthly-ish). `build_kernel.sh` makes this a one-command job; the version
   audit in §1 should be re-run per release.
5. `IO_URING` and `USER_NS` remain enabled for compatibility. A "max
   hardening" variant can disable `IO_URING` (`--disable IO_URING`) at the
   cost of some database/runtime performance.

---

## 6. Verification

Run after building (see `README.md`):

```
uname -r                                # 6.12.115-promptli
sysctl kernel.sched_bore                 # BORE master switch (1 = on)
sysctl kernel.sched_burst_smoothness     # BORE tuning knobs:
sysctl kernel.sched_burst_penalty_scale  #   sched_burst_inherit_type,
sysctl kernel.sched_burst_penalty_offset #   sched_burst_protect_slice_lv, ...
cat /proc/version                        # build provenance
```

Measured results from the QEMU test run are recorded in `TEST-RESULTS.md`.
