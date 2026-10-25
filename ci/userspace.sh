#!/bin/bash
# Publishes the kernel-independent half of one driver version as the GitHub release nvidia-<drv>:
# Unraid's stock unraid-nvidia-driver package (libraries, firmware, container toolkit) without its
# kernel modules. Any kernel's stock package will do, so a driver stays buildable after Unraid stops
# publishing it for new kernels. Does nothing if the release is complete (has userspace.json, uploaded last).
# Usage: ci/userspace.sh <driver>      Needs: gh (GH_TOKEN, GH_REPO), git, jq, curl, xz, GNU tar. Run as root.
set -euo pipefail
DRV="${1:?driver version}"
TAG="nvidia-$DRV"
PKG="cmp170hx-nvidia-${DRV}-x86_64-1.txz"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
die() { echo "ERROR: $*" >&2; exit 1; }

if gh release view "$TAG" --json assets --jq '.assets[].name' 2>/dev/null | grep -qx userspace.json; then
  echo "$TAG already published"; exit 0
fi
gh release delete "$TAG" --yes 2>/dev/null || true    # leftover of an interrupted run (the tag stays)

# newest Unraid kernel release that has this driver (no "| head": gh would die of SIGPIPE under pipefail)
src="$(gh api --paginate repos/unraid/unraid-nvidia-driver/releases \
  --jq ".[] | .tag_name as \$t | .assets[] | select(.name == \"nvidia-${DRV}-\" + \$t + \"-1.txz\") | \$t")"
src="${src%%$'\n'*}"
[ -n "$src" ] || die "no stock package for $DRV in any unraid-nvidia-driver release"
stock="nvidia-${DRV}-${src}-1.txz"
url="https://github.com/unraid/unraid-nvidia-driver/releases/download/$src"
echo "==> $DRV from $src"
curl -fsSL -o "$WORK/$stock" "$url/$stock"
[ "$(md5sum "$WORK/$stock" | cut -d' ' -f1)" = "$(curl -fsSL "$url/$stock.md5" | cut -d' ' -f1)" ] \
  || die "md5 mismatch on $stock"

mkdir "$WORK/pkg"
tar -xJpf "$WORK/$stock" --numeric-owner -C "$WORK/pkg"
rm -f "$WORK/$stock"
[ -f "$WORK/pkg/lib/firmware/nvidia/$DRV/gsp_ga10x.bin" ] || die "GSP firmware missing"
[ -x "$WORK/pkg/usr/bin/nvidia-smi" ] && [ -x "$WORK/pkg/usr/bin/nvidia-ctk" ] || die "nvidia-smi/nvidia-ctk missing"
rm -rf "$WORK/pkg/lib/modules"
# the stock package ships some directories (lib/, usr/lib64/, install/) as 0777; installpkg would apply that
find "$WORK/pkg" -type d -perm -0002 -exec chmod 0755 {} +
echo "cmp170hx-nvidia: Nvidia ${DRV} userspace for the CMP 170HX Unlock Driver (from ${stock})" \
  > "$WORK/pkg/install/slack-desc"

tar --numeric-owner --owner=0 --group=0 -C "$WORK/pkg" -cf - . | xz -T0 -6 > "$WORK/$PKG"
md5="$(md5sum "$WORK/$PKG" | cut -d' ' -f1)"
echo "$md5" > "$WORK/$PKG.md5"
jq -n --arg f "$PKG" --arg p "$TAG/$PKG" --arg d "$DRV" --arg s "$src" --arg m "$md5" \
  --arg h "$(sha256sum "$WORK/$PKG" | cut -d' ' -f1)" --argjson z "$(stat -c %s "$WORK/$PKG")" \
  '{file:$f, path:$p, driver:$d, source_kernel:$s, md5:$m, sha256:$h, size:$z}' > "$WORK/userspace.json"

bash "$(dirname "$0")/release-tag.sh" "$TAG"
gh release create "$TAG" --target "$CI_COMMIT_SHA" --title "Nvidia $DRV userspace" \
  --notes "Nvidia $DRV userspace (libraries, firmware, container toolkit) taken from the stock unraid-nvidia-driver package $stock with its kernel modules removed. Installed by the CMP 170HX Unlock Driver plugin together with a modules package from a kernel release; do not install by hand." \
  "$WORK/$PKG" "$WORK/$PKG.md5"
gh release upload "$TAG" "$WORK/userspace.json"
echo "==> published $TAG"
