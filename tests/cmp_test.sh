#!/bin/bash
# Off-box tests for cmp.sh: system commands are stubbed, a local HTTP server plays the GitHub releases.
# Usage: bash tests/cmp_test.sh      Needs: bash, curl, jq, python3, md5sum/sha256sum.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMP="$ROOT/source/usr/local/emhttp/plugins/cmp170hx-unlock-driver/include/cmp.sh"
T="$(mktemp -d)"
PORT=$((20000 + RANDOM % 20000))
KVER="$(uname -r)"          # the running kernel, so cmp.sh does not switch to dry-run
FAILS=0

# ---------------------------------------------------------------- stubs
mkdir -p "$T/bin" "$T/www"
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
stub lspci      'cat "$TEST_DIR/lspci" 2>/dev/null'
stub installpkg 'echo "$(basename "$1")" >> "$TEST_DIR/installed"'
stub modinfo    'grep -q . "$TEST_DIR/installed" 2>/dev/null'     # "installed" once a package was installed
for c in rmmod depmod logger nvidia-ctk; do stub "$c" 'exit 0'; done
stub modprobe   '[ ! -f "$TEST_DIR/no_gpu_driver" ]'      # touch no_gpu_driver: the module fails to load
stub crontab    'if [ "${1:-}" = -l ]; then cat "$TEST_DIR/crontab" 2>/dev/null; else cat > "$TEST_DIR/crontab"; fi'
export PATH="$T/bin:$PATH" TEST_DIR="$T"
export CMP_PLUGIN_DIR="$T/flash" CMP_RUN_DIR="$T/run" CMP_ETC="$T/etc" CMP_HAMMER="$T/none" \
       CMP_NOTIFY="$T/bin/notify" CMP_BASE_URL="http://127.0.0.1:$PORT" CMP_KVER="$KVER" \
       CMP_UNRAID_RELEASES="http://127.0.0.1:$PORT/os"
stub notify 'echo "$*" >> "$TEST_DIR/notifications"'

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$T/www" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 50); do curl -s "$CMP_BASE_URL/" >/dev/null && break; sleep 0.1; done

# ---------------------------------------------------------------- fake releases
# publish <driver> <ref> <profile>...: a modules package per profile in release $KVER, plus nvidia-<driver>
publish() {
  local drv="$1" ref="$2" p f us; shift 2
  mkdir -p "$T/www/$KVER" "$T/www/nvidia-$drv"
  us="cmp170hx-nvidia-$drv-x86_64-1.txz"
  echo "userspace $drv" > "$T/www/nvidia-$drv/$us"
  entry() { jq -nc --arg f "$1" --arg p "$2/$1" --arg m "$(md5sum "$T/www/$2/$1" | cut -d' ' -f1)" \
              --arg s "$(sha256sum "$T/www/$2/$1" | cut -d' ' -f1)" --argjson z "$(stat -c %s "$T/www/$2/$1")" \
              '{file:$f, path:$p, md5:$m, sha256:$s, size:$z}'; }
  [ -f "$T/www/$KVER/manifest.json" ] || echo '{"schema":2,"packages":[],"userspace":{}}' > "$T/www/$KVER/manifest.json"
  for p in "$@"; do
    f="cmp170hx-modules-$drv-$ref-$p-$KVER-1.txz"
    echo "modules $drv $ref $p" > "$T/www/$KVER/$f"
    jq --argjson e "$(entry "$f" "$KVER")" --arg d "$drv" --arg r "$ref" --arg p "$p" \
      '.packages += [$e + {driver:$d, cmpunlocker:$r, profile:$p}]' "$T/www/$KVER/manifest.json" > "$T/m" && mv "$T/m" "$T/www/$KVER/manifest.json"
  done
  jq --argjson e "$(entry "$us" "nvidia-$drv")" --arg d "$drv" '.userspace[$d] = ($e + {driver:$d})' \
    "$T/www/$KVER/manifest.json" > "$T/m" && mv "$T/m" "$T/www/$KVER/manifest.json"
}

reset() { (cd "$T" && rm -rf flash run etc www/* installed notifications crontab lspci no_gpu_driver); }
card() { case "$1" in 8gb) echo '01:00.0 3D controller [0302]: NVIDIA Corporation GA100 [10de:20c2] (rev a1)' ;;
                      10gb) echo '02:00.0 3D controller [0302]: NVIDIA Corporation GA100 [10de:2082] (rev a1)' ;; esac >> "$T/lspci"; }
boot() { bash "$CMP" boot >/dev/null 2>&1; }
state() { sed -n 's/^status=//p' "$T/run/state"; }

check() { # <description> <command...>
  if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; FAILS=$((FAILS + 1)); fi
}
not() { ! "$@"; }
installed() { [ "$(tr '\n' ' ' < "$T/installed" 2>/dev/null)" = "$1" ]; }

# ---------------------------------------------------------------- tests
reset
boot
check "no card: nothing installed"                  [ "$(state)" = no_gpu ]

reset; card 8gb
boot
check "unpublished kernel: unsupported"             [ "$(state)" = unsupported ]
check "unpublished kernel: user notified"           grep -q "not supported yet" "$T/notifications"

reset; card 8gb; publish 615.71.09 v0.5 8gb 10gb mixed
boot
check "8gb card: installed"                         [ "$(state)" = installed ]
check "8gb card: userspace then 8gb modules"        installed "cmp170hx-nvidia-615.71.09-x86_64-1.txz cmp170hx-modules-615.71.09-v0.5-8gb-$KVER-1.txz "
check "8gb card: both packages cached"              [ -f "$T/flash/packages/$KVER/cmp170hx-modules-615.71.09-v0.5-8gb-$KVER-1.txz.json" ] && [ -f "$T/flash/packages/nvidia/cmp170hx-nvidia-615.71.09-x86_64-1.txz.md5" ]
check "8gb card: gen2 modprobe option"              grep -q RmForceEnableGen2 "$T/etc/modprobe.d/cmp-pcie-gen2.conf"
check "8gb card: first-install cold boot notice"    grep -q "cold boot" "$T/notifications"

# next boot: tmpfs is fresh, flash cache stays, release server is gone
rm -rf "$T/run" "$T/installed"; kill $SERVER; wait $SERVER 2>/dev/null
boot
check "reboot offline: installed from cache"        [ "$(state)" = installed ]
check "reboot offline: same two packages"           installed "cmp170hx-nvidia-615.71.09-x86_64-1.txz cmp170hx-modules-615.71.09-v0.5-8gb-$KVER-1.txz "
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$T/www" >/dev/null 2>&1 &
SERVER=$!
for _ in $(seq 50); do curl -s "$CMP_BASE_URL/" >/dev/null && break; sleep 0.1; done

reset; card 10gb; publish 615.71.09 v0.5 8gb 10gb; publish 615.78.08 v0.6 10gb
boot
check "latest: newest driver and tag"               installed "cmp170hx-nvidia-615.78.08-x86_64-1.txz cmp170hx-modules-615.78.08-v0.6-10gb-$KVER-1.txz "

reset; card 10gb; publish 615.71.09 v0.5 10gb; publish 615.78.08 v0.6 10gb
mkdir -p "$T/flash"; printf 'driver_version=615.71.09\n' > "$T/flash/settings.cfg"
boot
check "pinned driver is honored"                    installed "cmp170hx-nvidia-615.71.09-x86_64-1.txz cmp170hx-modules-615.71.09-v0.5-10gb-$KVER-1.txz "

reset; card 10gb; publish 615.71.09 v0.5 10gb
mkdir -p "$T/flash"; printf 'driver_version=999.1.1\n' > "$T/flash/settings.cfg"
boot
check "unavailable pin: falls back and notifies"    grep -q "Selected driver version unavailable" "$T/notifications"
check "unavailable pin: newest installed"           installed "cmp170hx-nvidia-615.71.09-x86_64-1.txz cmp170hx-modules-615.71.09-v0.5-10gb-$KVER-1.txz "

reset; card 8gb; publish 615.71.09 v0.5 8gb
echo corrupted >> "$T/www/nvidia-615.71.09/cmp170hx-nvidia-615.71.09-x86_64-1.txz"
boot
check "bad checksum: nothing installed"             [ ! -s "$T/installed" ] && [ "$(state)" = error ]
check "bad checksum: no partial file kept"          [ -z "$(find "$T/flash/packages" -name '*.part')" ]

reset; card 8gb; publish 615.71.09 v0.5 8gb 10gb
mkdir -p "$T/flash"; printf 'card_profile=10gb\n' > "$T/flash/settings.cfg"
boot
check "profile contradicting the card: refused"     [ "$(state)" = profile_mismatch ] && [ ! -s "$T/installed" ]

reset; publish 615.71.09 v0.5 8gb; touch "$T/no_gpu_driver"     # no card, profile forced (manual test on Hisa)
mkdir -p "$T/flash"; printf 'card_profile=8gb\n' > "$T/flash/settings.cfg"
boot
check "forced profile, no card: packages installed" installed "cmp170hx-nvidia-615.71.09-x86_64-1.txz cmp170hx-modules-615.71.09-v0.5-8gb-$KVER-1.txz "
check "forced profile, no card: not_loaded state"   [ "$(state)" = not_loaded ]
boot
check "running boot again: still not_loaded"        [ "$(state)" = not_loaded ]

reset; card 8gb; publish 615.71.09 v0.5 8gb; boot
rm -rf "$T/run" "$T/installed"; echo 'driver_version=latest' >> "$T/flash/settings.cfg"
publish 615.78.08 v0.6 8gb
CMP_UNRAID_VERSION=7.3.4 bash "$CMP" check >/dev/null 2>&1
check "daily check: newer driver pre-downloaded"    [ -f "$T/flash/packages/$KVER/cmp170hx-modules-615.78.08-v0.6-8gb-$KVER-1.txz" ]
check "daily check: old packages dropped"           [ -z "$(find "$T/flash/packages" -name '*615.71.09*')" ]

reset; card 8gb; publish 615.71.09 v0.5 8gb; mkdir -p "$T/flash"
check "set: rejects bad values"                     not bash "$CMP" set card_profile 12gb 2>/dev/null
check "set: rejects unknown keys"                   not bash "$CMP" set foo bar 2>/dev/null
bash "$CMP" set update_check false
check "set: update_check=false removes cron"        not grep -q cmp.sh "$T/crontab" 2>/dev/null

bash "$CMP" uninstall >/dev/null
check "uninstall: flash and tmp state removed"      [ ! -e "$T/flash" ] && [ ! -e "$T/run" ]

echo
if [ "$FAILS" = 0 ]; then echo "all tests passed"; else echo "$FAILS test(s) failed"; exit 1; fi
