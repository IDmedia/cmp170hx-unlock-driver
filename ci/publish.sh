#!/bin/bash
# Adds the modules packages built in out/<kver>/ to the GitHub release <kver> and merges them into its
# manifest.json. Existing packages stay; manifest.json is uploaded last, so it only lists packages whose
# files are already downloadable, and every listed driver has a published userspace release.
# Usage: ci/publish.sh <kver>      Needs: gh (GH_TOKEN, GH_REPO), git, jq.
set -euo pipefail
KVER="${1:?kver}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out/$KVER"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
die() { echo "ERROR: $*" >&2; exit 1; }

ls "$OUT"/*.txz.json >/dev/null 2>&1 || die "nothing built in $OUT"

if ! gh release view "$KVER" >/dev/null 2>&1; then
  bash "$(dirname "$0")/release-tag.sh" "$KVER"
  gh release create "$KVER" --target "$CI_COMMIT_SHA" --title "$KVER" \
    --notes "Patched Nvidia kernel modules for Unraid kernel ${KVER}, built from cmpunlocker (GPL-2.0, https://github.com/amoghmunikote/cmpunlocker) on NVIDIA open-gpu-kernel-modules. manifest.json lists them with their userspace packages. Installed by the CMP 170HX Unlock Driver plugin; do not install by hand."
fi
gh release download "$KVER" -p manifest.json -O "$WORK/old.json" 2>/dev/null || echo '{"packages":[]}' > "$WORK/old.json"

# new entries replace old ones with the same file name
jq -s '[.[0].packages[], .[1:][]] | reverse | unique_by(.file) | sort_by(.driver, .cmpunlocker, .profile)' \
  "$WORK/old.json" "$OUT"/*.txz.json > "$WORK/packages.json"

echo '{}' > "$WORK/userspace.json"
for drv in $(jq -r '.[].driver' "$WORK/packages.json" | sort -u); do
  gh release download "nvidia-$drv" -p userspace.json -O "$WORK/u.json" --clobber || die "userspace release nvidia-$drv is not published"
  jq --arg d "$drv" --slurpfile u "$WORK/u.json" '.[$d] = $u[0]' "$WORK/userspace.json" > "$WORK/tmp" && mv "$WORK/tmp" "$WORK/userspace.json"
done

jq -n --arg k "$KVER" --arg t "$(date -u +%FT%TZ)" --slurpfile p "$WORK/packages.json" --slurpfile u "$WORK/userspace.json" \
  '{schema:2, kernel:$k, updated:$t, packages:$p[0], userspace:$u[0]}' > "$WORK/manifest.json"

gh release upload "$KVER" --clobber "$OUT"/*.txz "$OUT"/*.txz.md5
gh release upload "$KVER" --clobber "$WORK/manifest.json"
echo "==> $KVER: $(jq '.packages | length' "$WORK/manifest.json") packages published"
