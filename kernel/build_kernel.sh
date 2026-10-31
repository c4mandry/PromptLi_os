#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# promptLi OS — performance + hardening kernel builder
#
# Builds a CachyOS-style kernel for promptLi OS:
#   • BORE scheduler (Burst-Oriented Response Enhancer)   ← responsiveness
#   • CONFIG_PREEMPT=y (full preemption) + HZ=1000        ← low latency
#   • -march=x86-64-v3, GCC                               ← faster codegen
#   • MGLRU, zswap+zstd default on, THP=madvise           ← memory/IO
#   • TCP BBR default + CAKE/FQ available                 ← network
#   • extra hardening (ZERO_CALL_USED_REGS, SCHED_CORE,
#     BPF_JIT_ALWAYS_ON, KSPP set already in Debian cfg)  ← security
#   • optional attack-surface trim (ham radio, etc.)
#
# Usage:
#   ./build_kernel.sh [VERSION]
#
# Environment overrides:
#   VERSION=6.12.115     kernel version (default below)
#   MARCH=x86-64-v3      -march for the compiler (use x86-64 for old CPUs)
#   JOBS=4               parallel build jobs (4 is safe on a 8 GB machine)
#   BASE_CONFIG=auto     starting config; "auto" = /boot/config-$(uname -r)
#   SURFACE=1            1 = disable rarely-used protocol families
#   WORKDIR=/var/tmp/promptli-kernel
#   INSTALL=0            1 = dpkg -i the built packages + update-grub
#
# Output: $WORKDIR/linux-image-<ver>-promptli_*.deb (+ headers, libc-dev)
# ─────────────────────────────────────────────────────────────────────────────
set -eu

VERSION="${1:-${VERSION:-6.12.115}}"
MARCH="${MARCH:-x86-64-v3}"
JOBS="${JOBS:-4}"
BASE_CONFIG="${BASE_CONFIG:-auto}"
SURFACE="${SURFACE:-1}"
WORKDIR="${WORKDIR:-/var/tmp/promptli-kernel}"
INSTALL="${INSTALL:-0}"
BORE_COMMIT="${BORE_COMMIT:-1e2f57ad74e8b8b1d315c03b7abd8d74e40448b4}"

KMAJOR="${VERSION%%.*}"
KSRC="linux-$VERSION"
TARBALL="$KSRC.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v$KMAJOR.x/$TARBALL"
BORE_URL="https://raw.githubusercontent.com/firelzrd/bore-scheduler/$BORE_COMMIT/patches/stable/0001-linux6.12.37-bore-7.0.0.patch"

log() { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

command -v gcc >/dev/null || die "install: build-essential bison flex libssl-dev libelf-dev dwarves xz-utils dpkg-dev fakeroot debhelper"
for t in bison flex pahole dpkg-buildpackage; do
    command -v "$t" >/dev/null || die "missing build tool: $t"
done

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ── 1. Sources (verified against kernel.org) ──────────────────────────────
if [ ! -f "$TARBALL" ]; then
    log "downloading $TARBALL"
    curl -fL --retry 3 -o "$TARBALL.part" "$URL"
    mv "$TARBALL.part" "$TARBALL"
fi
log "verifying checksum"
SUM_URL="https://cdn.kernel.org/pub/linux/kernel/v$KMAJOR.x/sha256sums.asc"
EXPECTED=$(curl -fsSL "$SUM_URL" | grep " $TARBALL\$" | cut -d' ' -f1 || true)
ACTUAL=$(sha256sum "$TARBALL" | cut -d' ' -f1)
[ -n "$EXPECTED" ] || die "could not fetch checksum list"
[ "$EXPECTED" = "$ACTUAL" ] || die "sha256 mismatch for $TARBALL"

if [ ! -d "$KSRC" ]; then
    log "extracting $TARBALL"
    tar -xf "$TARBALL"
fi
cd "$KSRC"

# ── 2. BORE scheduler patch ────────────────────────────────────────────────
BORE_PATCH="$WORKDIR/bore-$VERSION.patch"
if [ ! -f "$BORE_PATCH" ]; then
    log "downloading BORE patch (pinned @ ${BORE_COMMIT%%????????})"
    curl -fL --retry 3 -o "$BORE_PATCH" "$BORE_URL"
fi
if grep -q "SCHED_BORE" kernel/sched/fair.c 2>/dev/null; then
    log "BORE already applied"
else
    log "applying BORE patch (zero fuzz)"
    patch -p1 -F0 < "$BORE_PATCH" > "$WORKDIR/bore-apply.log" 2>&1 || {
        tail -20 "$WORKDIR/bore-apply.log"; die "BORE patch did not apply cleanly to $VERSION"
    }
    if grep -qE "FAILED|fuzz" "$WORKDIR/bore-apply.log"; then
        tail -20 "$WORKDIR/bore-apply.log"; die "BORE patch needed fuzz — refusing to build"
    fi
fi

# ── 3. Base config ─────────────────────────────────────────────────────────
if [ "$BASE_CONFIG" = "auto" ]; then
    BASE_CONFIG="/boot/config-$(uname -r)"
fi
[ -f "$BASE_CONFIG" ] || die "base config not found: $BASE_CONFIG (set BASE_CONFIG=path)"
log "base config: $BASE_CONFIG"
cp "$BASE_CONFIG" .config

# ── 4. promptLi performance + hardening profile ────────────────────────────
log "applying promptLi kernel profile"
./scripts/config \
    --set-str LOCALVERSION "-promptli" \
    --enable SCHED_BORE --enable HZ_1000 --disable HZ_250 --disable HZ_300 \
    --enable PREEMPT --disable PREEMPT_VOLUNTARY --disable PREEMPT_NONE --enable PREEMPT_DYNAMIC \
    --disable SCHEDSTATS --enable SCHED_CORE \
    --enable ZSWAP --enable ZSWAP_DEFAULT_ON \
    --enable ZSWAP_COMPRESSOR_DEFAULT_ZSTD --disable ZSWAP_COMPRESSOR_DEFAULT_LZO \
    --disable TRANSPARENT_HUGEPAGE_ALWAYS --enable TRANSPARENT_HUGEPAGE_MADVISE \
    --enable TCP_CONG_BBR --enable DEFAULT_BBR --disable DEFAULT_CUBIC \
    --enable ZERO_CALL_USED_REGS --enable BPF_JIT_ALWAYS_ON \
    --enable INIT_ON_ALLOC_DEFAULT_ON --enable BUG_ON_DATA_CORRUPTION \
    --enable SLAB_FREELIST_HARDENED --enable SLAB_FREELIST_RANDOM \
    --enable HARDENED_USERCOPY --enable FORTIFY_SOURCE \
    --enable STACKPROTECTOR_STRONG --enable X86_KERNEL_IBT \
    --enable RANDOMIZE_KSTACK_OFFSET_DEFAULT --enable RANDOMIZE_BASE --enable RANDOMIZE_MEMORY \
    --enable STRICT_KERNEL_RWX --enable STRICT_MODULE_RWX \
    --enable BPF_UNPRIV_DEFAULT_OFF --disable LEGACY_TIOCSTI --disable DEVKMEM \
    --enable SECURITY_YAMA --enable SECURITY_APPARMOR --enable SECURITY_LOCKDOWN_LSM \
    2>/dev/null || true

if [ "$SURFACE" = "1" ]; then
    log "trimming unused protocol families (attack surface)"
    ./scripts/config \
        --disable HAMRADIO --disable AX25 --disable ROSE --disable NETROM \
        --disable MKISS --disable 6PACK --disable BPQETHER \
        --disable ATALK --disable NFC --disable IEEE802154 \
        2>/dev/null || true
fi

make olddefconfig >/dev/null

# Sanity check the headline options actually took.
for opt in CONFIG_SCHED_BORE=y CONFIG_HZ=1000 CONFIG_PREEMPT=y CONFIG_DEFAULT_BBR=y \
           CONFIG_LRU_GEN=y CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y CONFIG_ZERO_CALL_USED_REGS=y; do
    grep -qx "$opt" .config || die "config option missing after olddefconfig: $opt"
done
log "config OK (BORE, PREEMPT, HZ=1000, BBR, hardening)"

# ── 5. Build .deb packages ─────────────────────────────────────────────────
log "building (j$JOBS, -march=$MARCH) — this takes a while"
if ! make -j"$JOBS" KCFLAGS="-march=$MARCH" bindeb-pkg > "$WORKDIR/build.log" 2>&1; then
    tail -40 "$WORKDIR/build.log"
    die "build failed (full log: $WORKDIR/build.log)"
fi
log "build finished (log: $WORKDIR/build.log)"

# ── 6. Report ──────────────────────────────────────────────────────────────
log "packages:"
ls -lh "$WORKDIR"/linux-image-*"$VERSION"-promptli*.deb "$WORKDIR"/linux-headers-*"$VERSION"-promptli*.deb 2>/dev/null || true

if [ "$INSTALL" = "1" ]; then
    log "installing the new kernel"
    dpkg -i "$WORKDIR"/linux-image-*"$VERSION"-promptli*.deb "$WORKDIR"/linux-headers-*"$VERSION"-promptli*.deb
    update-grub
    log "done — reboot to use $VERSION-promptli"
fi
