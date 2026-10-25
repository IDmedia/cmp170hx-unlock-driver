#!/bin/bash
# CMP 170HX Unlock Driver - plugin backend.
#   cmp.sh boot             install the patched driver for the running kernel (called by the .plg at boot)
#   cmp.sh download         fetch the package selected in settings into the flash cache (reboot applies it)
#   cmp.sh check            daily cron: upgrade-support warning + driver update download
#   cmp.sh upgrade-check    only the "is the next Unraid release supported" check
#   cmp.sh set <key> <val>  change a setting
#   cmp.sh diag             print a support bundle
#   cmp.sh uninstall        remove everything the plugin put on the system (called by the .plg remove step)
# Boot-path rule: this script never makes boot fail. Problems become a state + notification, exit 0.

NAME=cmp170hx-unlock-driver
PLUGIN="${CMP_PLUGIN_DIR:-/boot/config/plugins/$NAME}"   # CMP_* overrides exist for off-box tests
CFG=$PLUGIN/settings.cfg
PKGS=$PLUGIN/packages
RUN="${CMP_RUN_DIR:-/tmp/$NAME}"
ETC="${CMP_ETC:-/etc}"
HAMMER="${CMP_HAMMER:-/usr/local/sbin/cmp-gen2-hammer}"
SELF=/usr/local/emhttp/plugins/$NAME/include/cmp.sh
NOTIFY="${CMP_NOTIFY:-/usr/local/emhttp/plugins/dynamix/scripts/notify}"
UNRAID_RELEASES="${CMP_UNRAID_RELEASES:-https://releases.unraid.net/os}"
# Driver packages are releases of a separate, non-mirrored repo (same name as GH_REPO in .gitlab-ci.yml).
BASE="${CMP_BASE_URL:-https://github.com/IDmedia/cmp170hx-unlock-driver-packages/releases/download}"
# CMP_KVER simulates another kernel (testing the "unsupported" path); installs are skipped then.
KVER="${CMP_KVER:-$(uname -r)}"
DRY=0; [ "$KVER" = "$(uname -r)" ] || DRY=1

log() { echo "$*"; logger -t "$NAME" -- "$*" 2>/dev/null; }

# ---------------------------------------------------------------- settings
cfg_get() { grep -m1 "^$1=" "$CFG" 2>/dev/null | cut -d= -f2-; }

cfg_set() {
  mkdir -p "$PLUGIN"; touch "$CFG"
  if grep -q "^$1=" "$CFG"; then sed -i "s|^$1=.*|$1=$2|" "$CFG"; else echo "$1=$2" >> "$CFG"; fi
}

cfg_init() {
  mkdir -p "$PLUGIN" "$RUN"
  local kv k
  for kv in driver_version=latest cmpunlocker_ref=latest card_profile=auto gen2_enable=true \
            update_check=true first_installation=true; do
    k="${kv%%=*}"; grep -q "^$k=" "$CFG" 2>/dev/null || cfg_set "$k" "${kv#*=}"
  done
}

cmd_set() {
  local k="$1" v="$2"
  [[ "$v" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid value" >&2; return 1; }
  case "$k" in
    driver_version|cmpunlocker_ref) ;;
    card_profile) [[ "$v" =~ ^(auto|8gb|10gb|mixed)$ ]] || return 1 ;;
    gen2_enable|update_check) [[ "$v" =~ ^(true|false)$ ]] || return 1 ;;
    *) echo "unknown setting" >&2; return 1 ;;
  esac
  cfg_init; cfg_set "$k" "$v"
  if [ "$k" = update_check ]; then if [ "$v" = true ]; then cron_on; else cron_off; fi; fi
}

# ---------------------------------------------------------------- state shown on the settings page
set_state() { # status detail
  mkdir -p "$RUN"
  printf 'status=%s\ndetail=%s\nkernel=%s\n' "$1" "$2" "$KVER" > "$RUN/state"
}

# Notify once per distinct message. notify_once forgets at reboot ($RUN is in RAM), so a problem that
# persists is reported again after the next boot; notify_persistent remembers on flash (daily upgrade warnings).
notify_once()       { _notify "$RUN/notified" "$@"; }      # importance subject description
notify_persistent() { _notify "$PLUGIN/notified" "$@"; }
_notify() { # dedupe-file importance subject description
  [ "$DRY" = 1 ] && { echo "[dry-run notify:$2] $3 - $4"; return; }
  local h; h="$(printf '%s' "$3|$4" | md5sum | cut -d' ' -f1)"
  grep -qx "$h" "$1" 2>/dev/null && return
  mkdir -p "$(dirname "$1")"; echo "$h" >> "$1"
  [ -x "$NOTIFY" ] && "$NOTIFY" -e "CMP 170HX Unlock Driver" -s "$3" -d "$4" -i "$2" -l "/Settings/$NAME" >/dev/null 2>&1
}

cron_on() {
  crontab -l 2>/dev/null | grep -q "$NAME/include/cmp.sh check" && return
  (crontab -l 2>/dev/null; echo "$((RANDOM % 59)) $(shuf -i 8-9 -n 1) * * * $SELF check &>/dev/null") | crontab -
}
cron_off() { crontab -l 2>/dev/null | grep -v "$NAME/include/cmp.sh check" | crontab - 2>/dev/null || true; }

# ---------------------------------------------------------------- environment checks
conflict() { [ -f /boot/config/plugins/nvidia-driver.plg ] || [ -f /var/log/plugins/nvidia-driver.plg ]; }

# Prints 8gb|10gb|mixed for the CMP 170HX cards present, nothing if none.
detect_profile() {
  local ids
  ids="$(lspci -nn 2>/dev/null | grep -oiE '10de:(20c2|2082)' | tr '[:upper:]' '[:lower:]' | sort -u | tr '\n' ' ')"
  case "$ids" in
    "10de:20c2 ") echo 8gb ;;
    "10de:2082 ") echo 10gb ;;
    *20c2*2082*|*2082*20c2*) echo mixed ;;
  esac
}

# ---------------------------------------------------------------- release manifest
# fetch_manifest <kver>: 0 = manifest cached in $RUN, 2 = no release for this kernel (unsupported),
# 3 = could not find out (network/other). Never report "unsupported" unless the server said 404.
fetch_manifest() {
  mkdir -p "$RUN"
  local f="$RUN/manifest-$1.json" code
  code="$(curl -sSL --max-time 20 -o "$f.tmp" -w '%{http_code}' "$BASE/$1/manifest.json" 2>/dev/null)" || code=000
  case "$code" in
    200) if jq -e '.packages | length > 0' "$f.tmp" >/dev/null 2>&1; then mv "$f.tmp" "$f"; return 0; fi
         rm -f "$f.tmp"; return 3 ;;
    404) rm -f "$f.tmp"; return 2 ;;
    *)   rm -f "$f.tmp"; return 3 ;;
  esac
}

# select_pkg <manifest> <profile>: sets PICK (modules package JSON), PICK_USERSPACE (the userspace package
# of its driver) and PICK_FALLBACK; returns 1 if nothing fits.
# Not meant for $(...): the globals would be lost in the subshell.
# Honors settings; if the chosen driver/ref/profile combination was not built, falls back to the
# newest build for the profile (PICK_FALLBACK=1) rather than leaving the card without a driver.
select_pkg() {
  local m="$1" prof="$2" drv ref
  PICK=""; PICK_FALLBACK=0
  drv="$(cfg_get driver_version)"; ref="$(cfg_get cmpunlocker_ref)"
  [ "$drv" = latest ] && drv="$(jq -r --arg p "$prof" '[.packages[]|select(.profile==$p)|.driver]|unique[]' "$m" | sort -V | tail -1)"
  [ "$ref" = latest ] && ref="$(jq -r --arg p "$prof" --arg d "$drv" '[.packages[]|select(.profile==$p and .driver==$d)|.cmpunlocker]|unique[]' "$m" | sort -V | tail -1)"
  PICK="$(jq -c --arg p "$prof" --arg d "$drv" --arg r "$ref" '[.packages[]|select(.profile==$p and .driver==$d and .cmpunlocker==$r)][0] // empty' "$m")"
  if [ -z "$PICK" ]; then
    PICK_FALLBACK=1
    drv="$(jq -r --arg p "$prof" '[.packages[]|select(.profile==$p)|.driver]|unique[]' "$m" | sort -V | tail -1)"
    ref="$(jq -r --arg p "$prof" --arg d "$drv" '[.packages[]|select(.profile==$p and .driver==$d)|.cmpunlocker]|unique[]' "$m" | sort -V | tail -1)"
    PICK="$(jq -c --arg p "$prof" --arg d "$drv" --arg r "$ref" '[.packages[]|select(.profile==$p and .driver==$d and .cmpunlocker==$r)][0] // empty' "$m")"
  fi
  [ -n "$PICK" ] || return 1
  PICK_USERSPACE="$(jq -c --arg d "$drv" '.userspace[$d] // empty' "$m")"
  [ -n "$PICK_USERSPACE" ]
}

# Profile to build for: settings override, else detected. Refuses an override that contradicts the
# card (patched memory geometry on the wrong card), except 'mixed' which is valid anywhere.
resolve_profile() {
  local want det; want="$(cfg_get card_profile)"; det="$(detect_profile)"
  [ -z "$want" ] && want=auto
  if [ "$want" = auto ]; then
    [ -n "$det" ] || return 2
    echo "$det"; return 0
  fi
  if [ -n "$det" ] && [ "$want" != "$det" ] && [ "$want" != mixed ]; then
    echo "$want|$det"; return 3
  fi
  echo "$want"
}

# The driver comes as two packages, each cached on flash next to its manifest entry (<file>.json):
#   $PKGS/$KVER/cmp170hx-modules-*.txz   patched kernel modules, one per kernel
#   $PKGS/nvidia/cmp170hx-nvidia-*.txz   userspace, firmware and container toolkit, one per driver version,
#                                        so an Unraid upgrade that keeps the driver only downloads new modules
cached_modules() { ls -1 "$PKGS/$KVER"/cmp170hx-modules-*.txz 2>/dev/null | sort -V | tail -1; }
cached_userspace() { [ -n "$1" ] && ls -1 "$PKGS/nvidia/cmp170hx-nvidia-$1-"*.txz 2>/dev/null | tail -1; }  # <driver>
entry_of() { jq -r ".$2 // empty" "$1.json" 2>/dev/null; }   # <cached file> <field>

pkg_ok() { # <file>: md5 matches the sidecar
  [ -s "$1" ] && [ -s "$1.md5" ] && [ "$(md5sum "$1" | cut -d' ' -f1)" = "$(cut -d' ' -f1 < "$1.md5")" ]
}

# fetch <entry-json> <dir>: download one package into the flash cache and verify it.
fetch() {
  local e="$1" dir="$2" file md5 sha size need free
  file="$(jq -r .file <<<"$e")"; md5="$(jq -r .md5 <<<"$e")"; sha="$(jq -r .sha256 <<<"$e")"; size="$(jq -r .size <<<"$e")"
  mkdir -p "$dir"
  if pkg_ok "$dir/$file"; then log "package $file already cached"; return 0; fi
  need=$((size / 1048576 + 50)); free="$(df -m "$PLUGIN" | awk 'NR==2{print $4}')"
  [ "$free" -gt "$need" ] || { log "only ${free}MB free on /boot, need ${need}MB"; return 1; }
  log "downloading $file"
  curl -sSL --fail --max-time 1800 -o "$dir/$file.part" "$BASE/$(jq -r .path <<<"$e")" || { rm -f "$dir/$file.part"; return 1; }
  if [ "$(md5sum "$dir/$file.part" | cut -d' ' -f1)" != "$md5" ] || \
     [ "$(sha256sum "$dir/$file.part" | cut -d' ' -f1)" != "$sha" ]; then
    rm -f "$dir/$file.part"; log "checksum mismatch for $file"; return 1
  fi
  mv "$dir/$file.part" "$dir/$file"; echo "$md5" > "$dir/$file.md5"; echo "$e" > "$dir/$file.json"
}

# download_pick: fetch PICK and PICK_USERSPACE; only once both are verified, drop every other cached package.
download_pick() {
  local mod us
  fetch "$PICK" "$PKGS/$KVER" && fetch "$PICK_USERSPACE" "$PKGS/nvidia" || return 1
  mod="$(jq -r .file <<<"$PICK")"; us="$(jq -r .file <<<"$PICK_USERSPACE")"
  find "$PKGS/$KVER" -type f ! -name "$mod" ! -name "$mod.*" -delete
  find "$PKGS/nvidia" -type f ! -name "$us" ! -name "$us.*" -delete
  find "$PKGS" -mindepth 1 -maxdepth 1 -type d ! -name "$KVER" ! -name nvidia -exec rm -rf {} + 2>/dev/null
  return 0
}

# ---------------------------------------------------------------- driver install
post_install() {
  nvidia-ctk cdi generate --output="$ETC/cdi/nvidia.yaml" >/dev/null 2>&1
  if [ -f "$ETC/cdi/nvidia.yaml" ] && ! grep -q '/usr/lib/x86_64-linux-gnu/gbm/nvidia-drm_gbm.so' "$ETC/cdi/nvidia.yaml"; then
    sed -i -E 's#^([[:space:]]*)- \.\./libnvidia-allocator\.so\.1::/usr/lib64/gbm/nvidia-drm_gbm\.so[[:space:]]*$#\1- ../libnvidia-allocator.so.1::/usr/lib64/gbm/nvidia-drm_gbm.so\n\1- --link\n\1- /usr/lib64/libnvidia-allocator.so.1::/usr/lib/x86_64-linux-gnu/gbm/nvidia-drm_gbm.so#' "$ETC/cdi/nvidia.yaml"
  fi
  mkdir -p "$ETC/nvidia-container-runtime"
  [ -f "$ETC/nvidia-container-runtime/config.toml" ] || printf '[nvidia-container-runtime]\nlog-level = "warning"\n' > "$ETC/nvidia-container-runtime/config.toml"
  sed -i 's/log-level = "info"/log-level = "warning"/' "$ETC/nvidia-container-runtime/config.toml"
}

# Gen2: the card only advertises Gen1 until the driver has been loaded once, so reload it, then retrain.
# Runs only right after a fresh install at boot (nothing uses the driver yet).
gen2_apply() {
  rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null
  modprobe nvidia && modprobe nvidia_uvm 2>/dev/null
  CMP170HX_GEN2_MAX_ITERATIONS=100 "$HAMMER" >/dev/null 2>&1
}

install_pkg() { # <userspace file> <modules file>
  installpkg "$1" >/dev/null && installpkg "$2" >/dev/null || return 1
  depmod --all >/dev/null 2>&1
  mkdir -p "$ETC/modprobe.d"
  if [ "$(cfg_get gen2_enable)" = true ]; then
    echo 'options nvidia NVreg_RegistryDwords="RmForceEnableGen2=1;RMPcieLinkSpeed=0x1"' > "$ETC/modprobe.d/cmp-pcie-gen2.conf"
  else
    rm -f "$ETC/modprobe.d/cmp-pcie-gen2.conf"
  fi
}

cmd_boot() {
  cfg_init
  if conflict; then
    set_state conflict "Nvidia Driver plugin is installed"
    log "Nvidia Driver plugin present, not installing the patched driver"
    notify_once alert "Plugin conflict" "The Nvidia Driver plugin and CMP 170HX Unlock Driver cannot be installed together. Remove one of them, then reboot."
    return 0
  fi
  cron_off; [ "$(cfg_get update_check)" = true ] && cron_on
  if grep -qs '# cmp-unraid gen2' /boot/config/go; then
    notify_once warning "Old cmpunraider setup found" "/boot/config/go still has the cmpunraider Gen2 line. Run 'bash cmpunraider.sh uninstall' (or remove the line marked '# cmp-unraid gen2' and /boot/config/modprobe.d/cmp-pcie-gen2.conf), then reboot."
  fi

  local prof; prof="$(resolve_profile)"
  case $? in
    2) set_state no_gpu "no CMP 170HX detected"; log "no CMP 170HX detected, nothing to install"; return 0 ;;
    3) set_state profile_mismatch "$prof"; log "profile setting ${prof%|*} contradicts detected card ${prof#*|}"
       notify_once alert "Card profile mismatch" "The card profile is set to ${prof%|*} but a ${prof#*|} card was detected. Fix it in Settings > CMP 170HX Unlock Driver; no driver was installed."
       return 0 ;;
  esac

  # cached pair: modules for this kernel and card profile, plus the userspace of the same driver version
  local pkg us=""; pkg="$(cached_modules)"
  { [ -n "$pkg" ] && pkg_ok "$pkg" && [ "$(entry_of "$pkg" profile)" = "$prof" ]; } || pkg=""
  [ -n "$pkg" ] && us="$(cached_userspace "$(entry_of "$pkg" driver)")"
  { [ -n "$us" ] && pkg_ok "$us"; } || pkg=""

  if [ -z "$pkg" ]; then
    fetch_manifest "$KVER"
    case $? in
      2) set_state unsupported "no patched driver published for kernel $KVER"
         log "no patched driver for kernel $KVER yet; nothing installed (settings kept)"
         notify_once alert "Kernel $KVER not supported yet" "There is no patched CMP 170HX driver for this Unraid version yet, so no GPU driver was installed. Array and Docker start normally. The driver installs automatically once support is published (reboot, or reinstall the plugin)."
         return 0 ;;
      3) set_state unknown "could not reach the release server"
         log "could not reach the release server; nothing installed"
         notify_once warning "CMP 170HX driver not installed" "Could not reach the release server to download the driver for kernel $KVER. Check your internet connection and reboot."
         return 0 ;;
    esac
    select_pkg "$RUN/manifest-$KVER.json" "$prof" || { set_state error "no package for profile $prof"; log "manifest has no package for profile $prof"; return 0; }
    if [ "$PICK_FALLBACK" = 1 ]; then notify_once warning "Selected driver version unavailable" "The selected driver/cmpunlocker version is not published for kernel $KVER; installed the newest available instead."; fi
    if [ "$DRY" = 1 ]; then log "[dry-run] would download $(jq -r .file <<<"$PICK")"; return 0; fi
    download_pick || { set_state error "download failed"; notify_once warning "CMP 170HX driver download failed" "The driver package could not be downloaded or verified. Nothing was installed; reboot to retry."; return 0; }
    pkg="$PKGS/$KVER/$(jq -r .file <<<"$PICK")"; us="$PKGS/nvidia/$(jq -r .file <<<"$PICK_USERSPACE")"
  fi
  [ "$DRY" = 1 ] && { log "[dry-run] would install $pkg"; return 0; }

  local fresh=0
  if modinfo nvidia >/dev/null 2>&1; then
    log "nvidia module already installed, not reinstalling"
  else
    install_pkg "$us" "$pkg" || { set_state error "driver packages could not be installed"; log "installing $us / $pkg failed"; notify_once alert "CMP 170HX driver not installed" "Installing the patched driver packages failed. See the system log and Download diagnostics on the plugin page."; return 0; }
    fresh=1
  fi
  if ! modprobe nvidia >/dev/null 2>&1; then
    set_state not_loaded "$(basename "$pkg")"; log "driver installed, but the nvidia module did not load"
    notify_once alert "CMP 170HX driver not loaded" "The patched driver is installed, but the nvidia kernel module did not load. Without a CMP 170HX in the server (e.g. a forced card profile) this is expected; otherwise see Download diagnostics on the plugin page."
    return 0
  fi
  if [ "$fresh" = 1 ] && [ "$(cfg_get gen2_enable)" = true ] && [ -x "$HAMMER" ]; then gen2_apply; fi
  post_install
  set_state installed "$(basename "$pkg")"
  if [ "$(cfg_get first_installation)" = true ]; then
    cfg_set first_installation false
    notify_once alert "CMP 170HX driver installed" "Power the server OFF completely and cold boot it once so the card finishes unlocking. If Docker was already running, disable and re-enable Docker (Settings > Docker) to pick up the GPU."
  fi
  log "patched driver ready ($(basename "$pkg"))"
}

# ---------------------------------------------------------------- downloads / checks
cmd_download() {
  cfg_init
  conflict && { echo "Nvidia Driver plugin is installed; remove it first."; return 1; }
  local prof; prof="$(resolve_profile)" || { echo "cannot resolve card profile ($prof)"; return 1; }
  fetch_manifest "$KVER"
  case $? in
    2) echo "No patched driver is published for kernel $KVER yet."; return 1 ;;
    3) echo "Could not reach the release server."; return 1 ;;
  esac
  select_pkg "$RUN/manifest-$KVER.json" "$prof" || { echo "No package for profile $prof."; return 1; }
  if [ "$PICK_FALLBACK" = 1 ]; then echo "Selected version not published for this kernel; using the newest available."; fi
  download_pick || { echo "Download failed."; return 1; }
  echo "Package ready: $(jq -r .file <<<"$PICK")"
  echo "Reboot (cold boot for a first install) to install it."
}

# Which kernel does an Unraid release ship? Reads its changelog: the first version number within a few
# lines of a "Linux kernel" heading (stable .md and next .txt both use that heading), else a
# "Linux kernel X.Y.Z" sentence.
release_kernel() { # <changelog-url>
  local t k; t="$(curl -sSL --max-time 20 "$1" 2>/dev/null)" || return 1
  k="$(awk 'tolower($0) ~ /^#+ *linux kernel/ {f=5; next} f>0 {print; f--}' <<<"$t" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$k" ] || k="$(grep -ioE 'linux kernel [0-9]+\.[0-9]+\.[0-9]+' <<<"$t" | head -1 | grep -oE '[0-9.]+$')"
  [ -n "$k" ] && echo "$k-Unraid"
}

# Writes $RUN/upgrade.json: one result per newer Unraid release; status is supported | unsupported | unknown.
# "supported" is only ever reported when our release manifest for that kernel exists.
cmd_upgrade_check() {
  mkdir -p "$RUN"
  local cur branches b r ver url kern st results='[]'
  # shellcheck disable=SC1091,SC2154   # /etc/unraid-version only exists on Unraid; it sets $version
  cur="$(. /etc/unraid-version 2>/dev/null; echo "$version")"
  [ -n "$cur" ] || cur="${CMP_UNRAID_VERSION:-}"
  [ -n "$cur" ] || { echo "cannot determine the running Unraid version" >&2; return 1; }
  branches="stable"; [[ "$cur" == *-* ]] && branches="stable next"
  for b in $branches; do
    r="$(curl -sS --max-time 20 "$UNRAID_RELEASES?branch=$b&current_version=$cur" 2>/dev/null)"
    [ "$(jq -r '.isNewer // false' <<<"$r" 2>/dev/null)" = true ] || continue
    ver="$(jq -r .version <<<"$r")"; url="$(jq -r .changelog <<<"$r")"
    kern="$(release_kernel "$url")"
    if [ -z "$kern" ]; then st=unknown
    else
      fetch_manifest "$kern"
      case $? in 0) st=supported ;; 2) st=unsupported ;; *) st=unknown ;; esac
    fi
    results="$(jq -c --arg v "$ver" --arg k "$kern" --arg s "$st" --arg b "$b" '. + [{version:$v,kernel:$k,status:$s,branch:$b}]' <<<"$results")"
    case "$st" in
      unsupported) notify_persistent warning "Do NOT upgrade to Unraid $ver yet" "Unraid $ver uses kernel $kern, and no patched CMP 170HX driver is published for it yet. Upgrading now would leave the GPU without a driver until support is added." ;;
      unknown)     notify_persistent normal "Cannot verify Unraid $ver" "Could not determine whether the CMP 170HX driver supports Unraid $ver. Check the plugin page before upgrading." ;;
    esac
  done
  jq -n --arg t "$(date +%s)" --arg c "$cur" --argjson r "$results" '{checked:($t|tonumber),current:$c,results:$r}' > "$RUN/upgrade.json"
}

# Called by the settings page: refresh kernel-support + upgrade info (throttled to once per 10 min unless "force").
cmd_refresh() {
  cfg_init
  local stamp="$RUN/refreshed"
  if [ "${1:-}" != force ] && [ -f "$stamp" ] && [ $(( $(date +%s) - $(stat -c %Y "$stamp") )) -lt 600 ]; then return 0; fi
  touch "$stamp"
  fetch_manifest "$KVER"; echo $? > "$RUN/manifest-status"
  cmd_upgrade_check
}

cmd_check() {
  cfg_init
  cmd_upgrade_check
  [ "$(cfg_get driver_version)" = latest ] || [ "$(cfg_get cmpunlocker_ref)" = latest ] || return 0
  conflict && return 0
  local prof old new
  prof="$(resolve_profile)" || return 0
  fetch_manifest "$KVER" || return 0
  select_pkg "$RUN/manifest-$KVER.json" "$prof" || return 0
  old="$(cached_modules)"; new="$PKGS/$KVER/$(jq -r .file <<<"$PICK")"
  [ "$old" = "$new" ] && return 0
  if [ "$DRY" = 1 ]; then log "[dry-run] would download $(jq -r .file <<<"$PICK")"; return 0; fi
  if download_pick; then
    notify_once normal "CMP 170HX driver update downloaded" "A new patched driver ($(jq -r '.driver + " / cmpunlocker " + .cmpunlocker' <<<"$PICK")) was downloaded. Reboot the server to install it."
  fi
}

# ---------------------------------------------------------------- support bundle / uninstall
cmd_diag() {
  echo "== plugin"; echo "kernel: $KVER"; cat /etc/unraid-version 2>/dev/null
  ls /boot/config/plugins/$NAME/*.txz 2>/dev/null; echo "-- settings"; cat "$CFG" 2>/dev/null
  echo "-- state"; cat "$RUN/state" 2>/dev/null; echo "-- upgrade"; cat "$RUN/upgrade.json" 2>/dev/null
  echo "-- cached packages"; ls -l "$PKGS/$KVER" "$PKGS/nvidia" 2>/dev/null
  echo "-- installed packages"; find /var/log/packages -maxdepth 1 \( -name 'cmp170hx*' -o -name '*nvidia*' \) -printf '%f\n' 2>/dev/null
  echo "== lspci"; lspci -nnk -d 10de: 2>/dev/null
  echo "== nvidia-smi"; nvidia-smi 2>&1 | head -40
  nvidia-smi -q -d ECC 2>&1 | head -30
  echo "== dmesg"; dmesg 2>/dev/null | grep -iE 'nvidia|nvrm|SEC2|PMA' | tail -80
  echo "== gen2.log"; tail -40 /var/log/gen2.log 2>/dev/null
  echo "== syslog"; grep "$NAME" /var/log/syslog 2>/dev/null | tail -40
}

cmd_uninstall() {
  cron_off
  local p
  for p in /var/log/packages/cmp170hx-modules-* /var/log/packages/cmp170hx-nvidia-*; do
    [ -e "$p" ] && removepkg "${p##*/}" >/dev/null 2>&1
  done
  rm -f "$ETC/modprobe.d/cmp-pcie-gen2.conf" "$ETC/cdi/nvidia.yaml"
  rm -rf "$RUN" "$PLUGIN"
  echo "Removed packages, cron entry, modprobe options and settings."
}

cmd="${1:-}"; shift || true
case "$cmd" in
  boot)          cmd_boot; exit 0 ;;   # boot must never fail
  download)      cmd_download ;;
  check)         cmd_check ;;
  upgrade-check) cmd_upgrade_check ;;
  refresh)       cmd_refresh "$@" ;;
  set)           cmd_set "$@" ;;
  diag)          cmd_diag ;;
  uninstall)     cmd_uninstall ;;
  *) echo "usage: $0 boot|download|check|upgrade-check|set <k> <v>|diag|uninstall" >&2; exit 2 ;;
esac
