#!/bin/bash
# Checks that the committed plugin package matches the .plg (version + md5) and the source tree, i.e.
# that source/makepkg-unraid.sh was run after the last change under source/.
# Usage: bash tests/plugin_package_test.sh      Needs: tar, xz, md5sum, diff.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=cmp170hx-unlock-driver
entity() { sed -n "s/.*<!ENTITY $1 *\"\([^\"]*\)\".*/\1/p" "$ROOT/$NAME.plg"; }
VERSION="$(entity version)"; MD5="$(entity md5)"
PKG="$ROOT/packages/$NAME-$VERSION.txz"
fail() { echo "FAIL $*"; echo "Run: bash source/makepkg-unraid.sh, then commit packages/ and the .plg"; exit 1; }

[ -f "$PKG" ] || fail "packages/$NAME-$VERSION.txz (the .plg version) does not exist"
[ "$(md5sum "$PKG" | cut -d' ' -f1)" = "$MD5" ] || fail "md5 of $PKG does not match the .plg"
grep -q "^###$VERSION" "$ROOT/$NAME.plg" || fail "no ###$VERSION entry in the .plg <CHANGES>"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
tar -xJf "$PKG" -C "$T"
diff -r "$ROOT/source/usr/local/emhttp/plugins/$NAME" "$T/usr/local/emhttp/plugins/$NAME" >/dev/null \
  || fail "package content differs from source/"
echo "ok   plugin package $VERSION matches the .plg and source/"
