#!/usr/bin/env bash
# =====================================================================
# build.sh — Win11 ARM64 bootable qcow2 "one-click" build (Apple Silicon Mac)
# Variables are provided by macos_build.sh (or export them yourself before running). File-type variables can be a URL or a local path:
#   URL -> download into files/ then use; local path -> use directly; zip -> extract into files/.
# Flow: resolve inputs -> 02 pack ISO -> 03 HVF install (auto shutdown) -> qemu-img compress.
# Requirements: brew install qemu wimlib xorriso
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"
# On exit (success or failure) remove the patcher image that build itself created, leaving the user's other images untouched (no prune)
trap 'docker image rm -f droidvm-patcher >/dev/null 2>&1 || true' EXIT
. "$HERE/common.sh"

for t in qemu-system-aarch64 wimlib-imagex xorriso; do
  command -v "$t" >/dev/null || { echo "missing $t — brew install qemu wimlib xorriso"; exit 1; }
done

# --- Display resolution (early fail-fast, so we do not finish 02 only to discover in 03 that the foreground is unavailable) ---
#   Set DISPLAY_OPT directly -> used as-is, no fallback (respects your explicit choice).
#   BACKGROUND=false(foreground) -> with a GUI session use the native window (cocoa); non-GUI (e.g. SSH) falls back to VNC automatically;
#                            exits only if VNC (5905) is also taken. "Only this foreground path has a fallback".
#   BACKGROUND=true/unset    -> VNC (headless default).
if [ -z "${DISPLAY_OPT:-}" ]; then
  case "${BACKGROUND:-true}" in
    false|0|no)
      if [ "$(launchctl managername 2>/dev/null)" = "Aqua" ]; then
        export DISPLAY_OPT="-display cocoa"; echo "[build] display: native qemu window (BACKGROUND=false)"
      elif ! (: >/dev/tcp/127.0.0.1/5905) 2>/dev/null; then
        export DISPLAY_OPT="-vnc 127.0.0.1:5"
        echo "[build] ⚠ BACKGROUND=false but not a GUI session (foreground unavailable) -> falling back to VNC: open vnc://127.0.0.1:5905"
      else
        echo "[build] ✗ foreground unavailable and VNC port 5905 already taken -> cannot display, exiting"; exit 1
      fi ;;
    *) export DISPLAY_OPT="-vnc 127.0.0.1:5" ;;
  esac
fi

# Resolve the install.wim edition index: IMAGE_INDEX empty or 0 -> list editions for the user to pick; set -> validate then use.
# Use wimlib-imagex to read install.wim inside the ISO (macOS has wimlib, no need for Windows DISM). Return the chosen index to stdout.
resolve_image_index() {
  local iso="$1" want="${IMAGE_INDEX:-0}" attach dev mnt wim list valid sel
  attach="$(hdiutil attach -readonly -nobrowse -noverify "$iso")"
  dev="$(printf '%s\n' "$attach" | grep -oE '/dev/disk[0-9]+' | head -1)"
  mnt="$(printf '%s\n' "$attach" | grep -oE '/Volumes/.*' | head -1)"
  wim="$mnt/sources/install.wim"
  [ -f "$wim" ] || { hdiutil detach "$dev" >/dev/null 2>&1 || true; echo "install.wim not found" >&2; return 1; }
  list="$(wimlib-imagex info "$wim" | awk '
    /^Index:/ {idx=$2}
    /^Name:/  {n=$0; sub(/^Name:[[:space:]]*/,"",n); print idx"\t"n}')"
  valid="$(printf '%s\n' "$list" | cut -f1)"
  hdiutil detach "$dev" >/dev/null 2>&1 || true
  [ -n "$valid" ] || { echo "install.wim has no editions" >&2; return 1; }

  if [ "$want" -gt 0 ] 2>/dev/null; then
    printf '%s\n' "$valid" | grep -qx "$want" && { printf '%s\n' "$want"; return 0; }
    echo "IMAGE_INDEX=$want not in this ISO; choices: $(echo $valid)" >&2; return 1
  fi
  echo "install.wim editions:" >&2
  printf '%s\n' "$list" | while IFS="$(printf '\t')" read -r i n; do echo "  [$i] $n" >&2; done
  [ -t 0 ] || { echo "IMAGE_INDEX unset and non-interactive; please set one of: $(echo $valid)" >&2; return 1; }
  while :; do
    printf "select image index: " >&2; read -r sel
    printf '%s\n' "$valid" | grep -qx "$sel" && { printf '%s\n' "$sel"; return 0; }
    echo "  invalid, please choose from: $(echo $valid)" >&2
  done
}

# --- Required variables (recommended to set via macos_build.sh) ---
: "${SRC_ISO:?set SRC_ISO (URL or path of the Win11 ARM64 ISO) — recommended via macos_build.sh}"
: "${DRIVERS_DIR:?set DRIVERS_DIR (URL or path of the driver zip/folder)}"

# --- Resolve file-type inputs to absolute paths, export to 02/03 (no longer scans inputs/) ---
SRC_ISO="$(resolve_file "$SRC_ISO" "win11-arm64.iso")"

# --- install.wim edition index (empty/0 = detect and ask). Used by both patches and autounattend ---
IMAGE_INDEX="$(resolve_image_index "$SRC_ISO")"
export IMAGE_INDEX   # so the 00-make-patches.sh called later can also read it
echo "[build] IMAGE_INDEX = $IMAGE_INDEX"

# --- Drivers: DRIVERS_DIR (zip/folder) is extracted/resolved into the "ZIP root"; a leading ZIP
#     prefix in DRIVER_DIR / DRIVER_CERT expands to that root. Afterwards only the drivers named by DRIVER_INSTALL + DRIVER_CERT are installed. ---
ZIP="$(resolve_dir "$(resolve_file "$DRIVERS_DIR" "gunyah-arm64-drivers.zip")")"
DRIVER_DIR="${DRIVER_DIR:-ZIP/drivers}"
DRIVER_CERT="${DRIVER_CERT:-}"
DRIVER_DIR="${DRIVER_DIR/#ZIP/$ZIP}"
[ -n "$DRIVER_CERT" ] && DRIVER_CERT="${DRIVER_CERT/#ZIP/$ZIP}"
[ -d "$DRIVER_DIR" ] || { echo "driver folder DRIVER_DIR not found: $DRIVER_DIR"; exit 1; }
[ -z "$DRIVER_CERT" ] || [ -f "$DRIVER_CERT" ] || { echo "DRIVER_CERT not found: $DRIVER_CERT"; exit 1; }

# --- testsigning BCD: if unspecified, auto-generate using a Colima container (the original Linux-side flow is merged in here).
#     If specified (URL or path), use it as-is, handled by resolve_file below. ---
if [ -z "${BCD_PATCHED:-}" ] || [ -z "${BCD_TEMPLATE:-}" ]; then
  echo "[build] === 1/4 generate testsigning BCD (Colima container) ==="
  bash "$HERE/00-make-patches.sh" "$SRC_ISO"
  BCD_PATCHED="$FILES/patches/bcd-patched"
  BCD_TEMPLATE="$FILES/patches/bcd-template-patched"
fi
BCD_PATCHED="$(resolve_file "$BCD_PATCHED" "bcd-patched")"
BCD_TEMPLATE="$(resolve_file "$BCD_TEMPLATE" "bcd-template-patched")"

# --- Account / SSH: USERNAME/PASSWORD injected into autounattend; OPENSSH_SRC resolved then staged (empty = do not install SSH) ---
USERNAME="${USERNAME:-USER}"
PASSWORD="${PASSWORD:-}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
OPENSSH_SRC="${OPENSSH_SRC:-}"
[ -n "$OPENSSH_SRC" ] && OPENSSH_SRC="$(resolve_file "$OPENSSH_SRC")"

export SRC_ISO IMAGE_INDEX DRIVER_DIR DRIVER_INSTALL DRIVER_CERT BCD_PATCHED BCD_TEMPLATE \
       USERNAME PASSWORD SSH_PUBKEY OPENSSH_SRC FILES

echo "[build] === 2/4 pack install ISO ==="
bash "$HERE/02-make-iso.sh"
echo "[build] === 3/4 HVF install (fully automatic, auto shutdown when done) ==="
bash "$HERE/03-run-install.sh"

echo "[build] === 4/4 compress qcow2 ==="
OUT_QCOW="${OUT_QCOW:-$HERE/win11-droidvm-final.qcow2}"   # final artifact goes in macos/
# convert only writes allocated clusters -> the artifact is compact/sparse (during install discard=unmap + debloat's
# Optimize-Volume -ReTrim already TRIMs guest-freed space in real time, so the working qcow2 itself does not bloat).
# COMPRESS non-empty adds -c (zlib-compress the clusters). NOTE: crosvm CANNOT read compressed clusters, so this is only
# for shipping to a DroidVM import / pre-flight that decompresses first (DroidVM's pre-start guard also detects it and
# offers to convert). Still bootable in plain qemu. Default off. (Plain string, not an array, for bash 3.2 on macOS.)
COMPRESS_FLAG=""; [ -n "${COMPRESS:-}" ] && COMPRESS_FLAG="-c"
qemu-img convert $COMPRESS_FLAG -O qcow2 "$FILES/win11-droidvm.qcow2" "$OUT_QCOW"
sz=$(ls -lh "$OUT_QCOW" | awk '{print $5}')
echo "[build] done ✅  -> $OUT_QCOW ($sz)"

# Wrap-up: delete large intermediate files (working qcow2 ~8G, setup ISO ~5G) to reclaim space for the Mac; download caches (files/patches,
# drivers, msi) are kept. Set KEEP_WORK=1 to keep intermediate files for debugging.
if [ -z "${KEEP_WORK:-}" ]; then
  rm -f "$FILES/win11-droidvm.qcow2" "$FILES/win11-droidvm-setup.iso" \
        "$FILES/edk2-arm-vars.fd" "$FILES/qmp.sock" "$FILES/clicker.log"
  echo "[build] cleaned intermediate files (KEEP_WORK=1 to keep them)"
fi
# Trim space freed inside the Colima VM (temp raw from the BCD patch, etc.) back to the Mac's disk image (best-effort)
colima ssh -- sudo fstrim -a >/dev/null 2>&1 || true
