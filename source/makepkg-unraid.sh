#!/bin/bash
# Builds the plugin UI package packages/cmp170hx-unlock-driver-<version>.txz (+ .md5) and stamps the
# version and md5 into cmp170hx-unlock-driver.plg. Run from anywhere on a Linux box or Unraid.
set -euo pipefail
NAME=cmp170hx-unlock-driver
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(date +%Y.%m.%d)}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/usr/local/emhttp/plugins" "$ROOT/packages"
cp -R "$ROOT/source/usr/local/emhttp/plugins/$NAME" "$TMP/usr/local/emhttp/plugins/"
chmod -R 755 "$TMP"
find "$TMP" -type f ! -name '*.sh' -exec chmod 644 {} +
OUT="$ROOT/packages/$NAME-$VERSION.txz"
rm -f "$ROOT/packages/$NAME"-*.txz "$ROOT/packages/$NAME"-*.txz.md5
if command -v makepkg >/dev/null; then
  (cd "$TMP" && makepkg -l y -c y "$OUT" >/dev/null)
else
  tar --owner=0 --group=0 -C "$TMP" -cJf "$OUT" .   # fallback: installpkg accepts a plain tar.xz
fi
MD5="$(md5sum "$OUT" | cut -d' ' -f1)"
echo "$MD5" > "$OUT.md5"
sed -i -E "s|(<!ENTITY version +\")[^\"]*|\1$VERSION|; s|(<!ENTITY md5 +\")[^\"]*|\1$MD5|" "$ROOT/$NAME.plg"
echo "built $OUT (md5 $MD5); plg updated"
