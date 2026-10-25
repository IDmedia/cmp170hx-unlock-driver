#!/bin/bash
# Runs INSIDE ghcr.io/ich777/unraid_kernel:gcc_<ver> (a build job of the generated child pipeline).
# Builds one patched kernel-modules package for one (kernel, driver, cmpunlocker tag, profile).
# The userspace half (libraries, firmware, container toolkit) is kernel independent: ci/userspace.sh.
set -euo pipefail
trap 'echo "ERROR line $LINENO: $BASH_COMMAND" >&2' ERR

: "${KVER:?}" "${DRV:?}" "${PROFILE:?}" "${CMPUNLOCKER_REF:?}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE=$ROOT/cache
OUT=$ROOT/out/$KVER
REF_SAFE=${CMPUNLOCKER_REF//[^A-Za-z0-9.]/_}      # Slackware names split on '-', keep refs dash-free
PKG="cmp170hx-modules-${DRV}-${REF_SAFE}-${PROFILE}-${KVER}-1.txz"
MODDIR="/lib/modules/${KVER}/updates/cmpunlocker"

die() { echo "ERROR: $*" >&2; exit 1; }
mkdir -p "$CACHE" "$OUT"
echo "==> kernel ${KVER}, driver ${DRV}, cmpunlocker ${CMPUNLOCKER_REF}, profile ${PROFILE}"

# The job runs on the runner's kernel, so uname -r is wrong. cmpunlocker's build.sh derives the kernel
# tree path from `uname -r`, so report the target kernel instead.
mkdir -p /usr/local/bin
cat > /usr/local/bin/uname <<'SH'
#!/bin/bash
case "${1:-}" in -r|--kernel-release) echo "$KVER" ;; *) exec /usr/bin/uname "$@" ;; esac
SH
chmod +x /usr/local/bin/uname

# The image's curl/git are broken (libnghttp3 drift). Shim curl with python; build.sh uses
# "curl -L --fail -o FILE URL", same as we do here.
cat > /usr/local/bin/curl <<'PY'
#!/usr/bin/python3
import sys, shutil, urllib.request
out = url = None; a = sys.argv[1:]; i = 0
while i < len(a):
    if a[i] == '-o': out = a[i+1]; i += 2; continue
    if not a[i].startswith('-'): url = a[i]
    i += 1
try:
    with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'curl'})) as r:
        if out:
            with open(out, 'wb') as f: shutil.copyfileobj(r, f)
        else:
            shutil.copyfileobj(r, sys.stdout.buffer)
except Exception as e:
    print(f"curl-shim: {url}: {e}", file=sys.stderr); sys.exit(22)
PY
chmod +x /usr/local/bin/curl
export PATH=/usr/local/bin:$PATH
[ "$(uname -r)" = "$KVER" ] || die "uname shim not active"

# 1. pre-compiled Unraid kernel tree (ich777) -> /lib/modules/$KVER/build. Kept across builds in one job.
if [ ! -f "/lib/modules/${KVER}/build/Module.symvers" ]; then
  KTAR="$CACHE/linux-${KVER}.tar.xz"
  [ -s "$KTAR" ] || curl -L --fail -o "$KTAR" \
    "https://github.com/ich777/unraid_kernel/releases/download/${KVER}/linux-${KVER}.tar.xz" \
    || die "no pre-compiled kernel tree for ${KVER}"
  rm -rf /kbuild && mkdir /kbuild
  tar -xJf "$KTAR" -C /kbuild
  KSRC="$(dirname "$(find /kbuild -maxdepth 4 -name Module.symvers -print -quit)")"
  [ -f "$KSRC/Makefile" ] || die "kernel tree not found in tarball"
  mkdir -p "/lib/modules/${KVER}"
  ln -sfn "$KSRC" "/lib/modules/${KVER}/build"
fi

# 2. cmpunlocker sources + PyYAML (build.sh needs it)
CTAR="$CACHE/cmpunlocker-${REF_SAFE}.tar.gz"
[ -s "$CTAR" ] || curl -L --fail -o "$CTAR" \
  "https://github.com/amoghmunikote/cmpunlocker/archive/refs/tags/${CMPUNLOCKER_REF}.tar.gz"
rm -rf "$CACHE/cmpunlocker" && mkdir -p "$CACHE/cmpunlocker"
tar -xzf "$CTAR" --strip-components=1 -C "$CACHE/cmpunlocker"
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -f "$CACHE/pyyaml/lib/yaml/__init__.py" ] || {
    curl -L --fail -o "$CACHE/pyyaml.tar.gz" https://github.com/yaml/pyyaml/archive/refs/tags/6.0.2.tar.gz
    mkdir -p "$CACHE/pyyaml" && tar -xzf "$CACHE/pyyaml.tar.gz" --strip-components=1 -C "$CACHE/pyyaml"
  }
  export PYTHONPATH="$CACHE/pyyaml/lib${PYTHONPATH:+:$PYTHONPATH}"
  python3 -c 'import yaml' || die "PyYAML import failed"
fi

# 3. build patched modules. build.sh ends by trying to reload modules on a live system, which
#    cannot work in a container; the .ko files are installed (and depmod run) before that point.
rm -rf "$MODDIR"
CMPUNLOCKER_DRIVER_VERSION="$DRV" CMPUNLOCKER_CARD_PROFILE="$PROFILE" \
CMPUNLOCKER_BUILD_DIR="$CACHE/build" \
  bash "$CACHE/cmpunlocker/driver/build.sh" || echo "(build.sh post-install step failed, expected in container)"
[ -f "$MODDIR/nvidia.ko" ] || die "patched nvidia.ko not produced, see output above"

# 4. package: modules at the path the stock package used, plus cmpunlocker metadata and the Gen2 helper
rm -rf /pkg && mkdir -p /pkg/install
VID="/pkg/lib/modules/${KVER}/kernel/drivers/video"
mkdir -p "$VID" "/pkg${MODDIR}" /pkg/usr/local/sbin
for m in nvidia nvidia-modeset nvidia-uvm nvidia-drm nvidia-peermem; do
  [ -f "$MODDIR/$m.ko" ] || continue
  strip --strip-debug "$MODDIR/$m.ko"
  install -m 0644 "$MODDIR/$m.ko" "$VID/$m.ko"
done
vermagic="$(strings "$VID/nvidia.ko" | sed -n 's/^vermagic=//p')"   # binutils is there, kmod may not be
vermagic="${vermagic%%$'\n'*}"
[ "${vermagic%% *}" = "$KVER" ] || die "nvidia.ko vermagic '$vermagic' does not match $KVER"
cp "$MODDIR"/{driver_version,card_profile,unlock_geometry,gpu_inventory} "/pkg${MODDIR}/" 2>/dev/null || true
echo "cmpunlocker ${CMPUNLOCKER_REF} $(date -u +%F) profile=${PROFILE}" > "/pkg${MODDIR}/unraid_build"
install -m 0755 "$CACHE/cmpunlocker/tools/hammer.sh" /pkg/usr/local/sbin/cmp-gen2-hammer
echo "cmp170hx-modules: CMP 170HX patched Nvidia ${DRV} modules (cmpunlocker ${CMPUNLOCKER_REF}, ${PROFILE}) for ${KVER}" \
  > /pkg/install/slack-desc

rm -f "$OUT/$PKG" "$OUT/$PKG".*
(cd /pkg && makepkg -l n -c n "$OUT/$PKG")
MD5="$(md5sum "$OUT/$PKG" | cut -d' ' -f1)"
SHA="$(sha256sum "$OUT/$PKG" | cut -d' ' -f1)"
echo "$MD5" > "$OUT/$PKG.md5"
# one manifest entry; ci/publish.sh merges these into the kernel's manifest.json
printf '{"file":"%s","path":"%s/%s","driver":"%s","profile":"%s","cmpunlocker":"%s","md5":"%s","sha256":"%s","size":%s}\n' \
  "$PKG" "$KVER" "$PKG" "$DRV" "$PROFILE" "$CMPUNLOCKER_REF" "$MD5" "$SHA" "$(stat -c %s "$OUT/$PKG")" > "$OUT/$PKG.json"
echo "==> built $OUT/$PKG ($(du -h "$OUT/$PKG" | cut -f1))"
